//
//  AccessTextExtractor.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Access
//  databases — Jet 3 (Access 97, 2 KiB pages, .mdb), Jet 4 (Access 2000–
//  2003, 4 KiB pages, .mdb) and ACE (Access 2007–2019, .accdb). The file is
//  a sequence of pages; page 0 is the header ("Standard Jet DB" / "Standard
//  ACE DB" at byte 4, the version byte at 20, and from byte 24 a region
//  XORed with a fixed 126-byte mask that holds the code page at 60, the
//  RC4 encoding key at 62 and the password at 66). A non-zero encoding key
//  means an encrypted database (RC4 for Jet, the Office cipher for ACE) —
//  reported as password-protected, nothing read, nothing bypassed. Page 2
//  is the table definition of the system catalog MSysObjects; its rows
//  (Name, Type, Flags, Id) name every user table (Type 1, no system flag,
//  not MSys*) and the page of each table's definition. A table definition
//  (page type 2, chained through the next-page pointer at 4) lists the
//  columns: type, number, variable-length index, flags, fixed offset and
//  length, then the names. Data pages (type 1, owner = the definition page)
//  hold rows addressed by a slot table (offset masked 0x1FFF; 0x8000 =
//  deleted, 0x4000 = overflow pointer to row/page); a row is the column
//  count, fixed values at their offsets, variable values located by the
//  offset table before the null mask (Jet 4) or by the Jet 3 jump table,
//  and the null mask at the end (bit set = present; Yes/No values live
//  there). Text is UTF-16LE (Jet 4+, with the FF FE compressed scheme that
//  toggles 8-bit and 16-bit runs on 0x00) or the code page (Jet 3); Memo
//  and OLE are LVAL records: inline, on one other page, or a chain of pages.
//  Layout after Jackcess (jackcess.sourceforge.io), verified on files
//  written by Access from Apache Tika's corpus.
//
//  Output: "[Table: Name]" then one line per row of "column=value" pairs
//  for text, memo, numbers, currency, dates, Yes/No; OLE columns are listed
//  as not text with their row count; binary, GUID and attachment/complex
//  columns are listed as not text. System tables are not dumped. Every
//  page is read by scanning the file, so no usage-map interpretation is
//  needed and no row is lost to a damaged map; a table that cannot be
//  decoded is recorded by name and the others are still read.
//

import Foundation

enum AccessTextExtractor {

    static let component = "Access tables"

    struct Issue: Error { let text: String; init(_ text: String) { self.text = text } }

    /// "Standard Jet DB" or "Standard ACE DB" at byte 4.
    static func hasSignature(_ head: Data) -> Bool {
        guard head.count >= 19 else { return false }
        let b = [UInt8](head[head.startIndex..<(head.startIndex + 19)])
        let engine = String(bytes: b[4..<19], encoding: .ascii) ?? ""
        return engine == "Standard Jet DB" || engine == "Standard ACE DB"
    }

    static let headerMask: [UInt8] = [
        0xB5, 0x6F, 0x03, 0x62, 0x61, 0x08, 0xC2, 0x55, 0xEB, 0xA9, 0x67, 0x72, 0x43, 0x3F, 0x00, 0x9C, 0x7A, 0x9F,
        0x90, 0xFF, 0x80, 0x9A, 0x31, 0xC5, 0x79, 0xBA, 0xED, 0x30, 0xBC, 0xDF, 0xCC, 0x9D, 0x63, 0xD9, 0xE4, 0xC3,
        0x7B, 0x42, 0xFB, 0x8A, 0xBC, 0x4E, 0x86, 0xFB, 0xEC, 0x37, 0x5D, 0x44, 0x9C, 0xFA, 0xC6, 0x5E, 0x28, 0xE6,
        0x13, 0xB6, 0x8A, 0x60, 0x54, 0x94, 0x7B, 0x36, 0xF5, 0x72, 0xDF, 0xB1, 0x77, 0xF4, 0x13, 0x43, 0xCF, 0xAF,
        0xB1, 0x33, 0x34, 0x61, 0x79, 0x5B, 0x92, 0xB5, 0x7C, 0x2A, 0x05, 0xF1, 0x7C, 0x99, 0x01, 0x1B, 0x98, 0xFD,
        0x12, 0x4F, 0x4A, 0x94, 0x6C, 0x3E, 0x60, 0x26, 0x5F, 0x95, 0xF8, 0xD0, 0x89, 0x24, 0x85, 0x67, 0xC6, 0x1F,
        0x27, 0x44, 0xD2, 0xEE, 0xCF, 0x65, 0xED, 0xFF, 0x07, 0xC7, 0x46, 0xA1, 0x78, 0x16, 0x0C, 0xED, 0xE9, 0x2D,
        0x62, 0xD4,
    ]

    // MARK: - Entry point

    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard hasSignature(data) else { throw OfficeTextExtractor.ExtractError.notAPackage("not an Access database (no Standard Jet DB / Standard ACE DB header)") }
        let limit = ExtractionLimits.effective.partBytes
        guard Int64(data.count) <= limit else {
            return OfficeTextExtractor.Result(text: "", components: [], skipped: ["\(fileURL.lastPathComponent) (\(data.count) bytes, over the \(limit)-byte guard)"], notText: [])
        }
        return try extract(bytes: [UInt8](data), name: fileURL.lastPathComponent)
    }

    static func extract(bytes: [UInt8], name: String) throws -> OfficeTextExtractor.Result {
        guard bytes.count >= 2048 else { throw OfficeTextExtractor.ExtractError.notAPackage("shorter than one page (\(bytes.count) bytes)") }
        let engine = String(bytes: bytes[4..<19], encoding: .ascii) ?? ""
        let format: Format
        switch bytes[20] {
        case 0: format = Format(jet3: true, version: "Access 97 (Jet 3)")
        case 1:
            if String(bytes: bytes[4..<19], encoding: .ascii) == "MSISAM Database" {
                throw OfficeTextExtractor.ExtractError.notAPackage("a Microsoft Money (MSISAM) file, which is always encoded — not read")
            }
            format = Format(jet3: false, version: "Access 2000–2003 (Jet 4)")
        case 2: format = Format(jet3: false, version: "Access 2007 (ACE)")
        case 3: format = Format(jet3: false, version: "Access 2010–2013 (ACE)")
        case 5: format = Format(jet3: false, version: "Access 2016 (ACE)")
        case 6: format = Format(jet3: false, version: "Access 2019 (ACE)")
        default: throw OfficeTextExtractor.ExtractError.notAPackage("\(engine) version byte \(bytes[20]) is not a known Access format")
        }
        guard bytes.count >= format.pageSize else {
            throw OfficeTextExtractor.ExtractError.notAPackage("\(format.version) file shorter than one \(format.pageSize)-byte page (\(bytes.count) bytes)")
        }
        let db = Database(bytes: bytes, format: format)
        // The masked header region: code page and encoding key.
        var header = Array(bytes[0..<format.pageSize])
        let maskLength = format.jet3 ? headerMask.count - 2 : headerMask.count
        for i in 0..<maskLength where 24 + i < header.count { header[24 + i] ^= headerMask[i] }
        let encodingKey = le32(header, 62)
        if encodingKey != 0 { throw OfficeTextExtractor.ExtractError.encrypted }
        db.textEncoding = format.jet3 ? codePageEncoding(Int(le16(header, 60))) : .utf16LittleEndian

        var text = "[Access database: \((name as NSString).deletingPathExtension) — \(format.version)]\n"
        var skipped: [String] = []
        var notText: [String] = []
        var tablesRead = 0

        let catalog: Table
        do { catalog = try db.table(definitionPage: 2, name: "MSysObjects") } catch let issue as Issue {
            throw OfficeTextExtractor.ExtractError.notAPackage("system catalog (page 2) could not be read: \(issue.text)")
        }
        var userTables: [(name: String, page: Int, hidden: Bool)] = []
        for row in catalog.rows() {
            guard case .int(let type)? = row["type"], type == 1,
                  case .text(let tableName)? = row["name"],
                  case .int(let page)? = row["id"] else { continue }
            let flags: Int
            if case .int(let f)? = row["flags"] { flags = f } else { flags = 0 }
            if flags & 0x2 != 0 || UInt32(truncatingIfNeeded: flags) & 0x8000_0000 != 0 { continue }
            if tableName.lowercased().hasPrefix("msys") { continue }
            userTables.append((tableName, page, flags & 0x08 != 0))
        }
        for entry in userTables {
            do {
                let table = try db.table(definitionPage: entry.page, name: entry.name)
                var lines: [String] = []
                var oleColumns: [String: Int] = [:]
                var otherNotText: Set<String> = []
                var undecodable = 0
                for row in table.rows(onError: { undecodable += 1 }) {
                    var cells: [String] = []
                    for column in table.columns {
                        guard let value = row[column.name.lowercased()] else { continue }
                        switch value {
                        case .text(let s): if !s.isEmpty { cells.append("\(column.name)=\(s)") }
                        case .int(let n): cells.append("\(column.name)=\(n)")
                        case .double(let d): cells.append("\(column.name)=\(formatDouble(d))")
                        case .decimal(let s): cells.append("\(column.name)=\(s)")
                        case .date(let s): cells.append("\(column.name)=\(s)")
                        case .bool(let b): cells.append("\(column.name)=\(b ? "Yes" : "No")")
                        case .ole: oleColumns[column.name, default: 0] += 1
                        case .binary(let kind): otherNotText.insert("\(entry.name).\(column.name) (\(kind))")
                        }
                    }
                    if !cells.isEmpty { lines.append(cells.joined(separator: "\t")) }
                }
                tablesRead += 1
                text += "[Table: \(entry.name)\(entry.hidden ? " (hidden)" : "")]\n"
                if lines.isEmpty { text += "(no rows)\n" } else { text += lines.joined(separator: "\n") + "\n" }
                text += "\n"
                for (column, count) in oleColumns.sorted(by: { $0.key < $1.key }) { notText.append("\(entry.name).\(column) (OLE objects in \(count) rows)") }
                notText.append(contentsOf: otherNotText.sorted())
                if undecodable > 0 { skipped.append("\(name): table \(entry.name) — \(undecodable) rows could not be decoded") }
            } catch let issue as Issue {
                skipped.append("\(name): table \(entry.name) — \(issue.text)")
            } catch {
                skipped.append("\(name): table \(entry.name) — \(error)")
            }
        }
        guard tablesRead > 0 else {
            if skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: "", components: [], skipped: skipped, notText: notText)
        }
        return OfficeTextExtractor.Result(text: text, components: [component], skipped: skipped, notText: notText)
    }

    // MARK: - Format constants (Jackcess JetFormat)

    struct Format {
        let jet3: Bool
        let version: String
        var pageSize: Int { jet3 ? 2048 : 4096 }
        // table definition
        var tableType: Int { jet3 ? 20 : 40 }
        var numCols: Int { jet3 ? 25 : 45 }
        var numIndexes: Int { jet3 ? 31 : 51 }
        var indexDefBlock: Int { jet3 ? 43 : 63 }
        var sizeIndexDefinition: Int { jet3 ? 8 : 12 }
        var sizeColumnHeader: Int { jet3 ? 18 : 25 }
        var columnNumber: Int { jet3 ? 1 : 5 }
        var columnVarIndex: Int { jet3 ? 3 : 7 }
        var columnFlags: Int { jet3 ? 13 : 15 }
        var columnExtFlags: Int { jet3 ? -1 : 16 }
        var columnScale: Int { 12 }
        var columnFixedOffset: Int { jet3 ? 14 : 21 }
        var columnLength: Int { jet3 ? 16 : 23 }
        var sizeNameLength: Int { jet3 ? 1 : 2 }
        // rows
        var rowStart: Int { jet3 ? 10 : 14 }
        var numRowsOnDataPage: Int { jet3 ? 8 : 12 }
        var sizeRowColumnCount: Int { jet3 ? 1 : 2 }
        var fixedDataRowOffset: Int { jet3 ? 1 : 2 }
        var sizeLongValueDef: Int { 12 }
    }

    // MARK: - Database, tables, rows

    enum Value {
        case text(String), int(Int), double(Double), decimal(String), date(String), bool(Bool)
        case ole, binary(String)
    }

    struct Column {
        let name: String
        let type: UInt8
        let number: Int
        let varIndex: Int
        let fixedOffset: Int
        let length: Int
        let isVariable: Bool
        let scale: Int
    }

    final class Database {
        let b: [UInt8]
        let format: Format
        var textEncoding: String.Encoding = .utf16LittleEndian
        var pageCount: Int { b.count / format.pageSize }

        init(bytes: [UInt8], format: Format) { b = bytes; self.format = format }

        func page(_ number: Int) -> ArraySlice<UInt8>? {
            guard number >= 0, number < pageCount else { return nil }
            let start = number * format.pageSize
            return b[start..<(start + format.pageSize)]
        }

        func table(definitionPage: Int, name: String) throws -> Table {
            guard let first = page(definitionPage) else { throw Issue("definition page \(definitionPage) is outside the file") }
            guard first[first.startIndex] == 0x02 else { throw Issue("page \(definitionPage) is not a table definition") }
            var def = Array(first)
            var next = Int(le32(def, 4))
            var seen: Set<Int> = [definitionPage]
            while next != 0 {
                guard seen.insert(next).inserted, let more = page(next) else { throw Issue("definition page chain is broken at page \(next)") }
                def.append(contentsOf: more.dropFirst(8))
                next = Int(le32(Array(more.prefix(8)), 4))
            }
            return try Table(db: self, definition: def, definitionPage: definitionPage, name: name)
        }
    }

    final class Table {
        let db: Database
        let definitionPage: Int
        let name: String
        private(set) var columns: [Column] = []
        private var format: Format { db.format }

        init(db: Database, definition d: [UInt8], definitionPage: Int, name: String) throws {
            self.db = db; self.definitionPage = definitionPage; self.name = name
            let f = db.format
            guard d.count > f.indexDefBlock + 4 else { throw Issue("definition is too short") }
            let columnCount = Int(le16(d, f.numCols))
            let indexCount = Int(Int32(bitPattern: le32(d, f.numIndexes)))
            guard indexCount >= 0, columnCount >= 0 else { throw Issue("negative counts in the definition") }
            let colOffset = f.indexDefBlock + indexCount * f.sizeIndexDefinition
            var pos = colOffset + columnCount * f.sizeColumnHeader
            guard pos <= d.count else { throw Issue("column headers run past the definition (\(columnCount) columns)") }
            var names: [String] = []
            for _ in 0..<columnCount {
                guard pos + f.sizeNameLength <= d.count else { throw Issue("column names run past the definition") }
                let length = f.sizeNameLength == 1 ? Int(d[pos]) : Int(le16(d, pos))
                pos += f.sizeNameLength
                guard length >= 0, pos + length <= d.count else { throw Issue("a column name runs past the definition") }
                names.append(String(bytes: d[pos..<(pos + length)], encoding: f.jet3 ? db.textEncoding : .utf16LittleEndian) ?? "column\(names.count + 1)")
                pos += length
            }
            for i in 0..<columnCount {
                let o = colOffset + i * f.sizeColumnHeader
                let flags = d[o + f.columnFlags]
                columns.append(Column(name: names[i], type: d[o], number: Int(le16(d, o + f.columnNumber)), varIndex: Int(le16(d, o + f.columnVarIndex)),
                                      fixedOffset: Int(le16(d, o + f.columnFixedOffset)), length: Int(le16(d, o + f.columnLength)),
                                      isVariable: flags & 0x01 == 0, scale: Int(d[o + f.columnScale])))
            }
            columns.sort { $0.number < $1.number }
        }

        /// Every live row, by scanning the file for this table's data pages.
        func rows(onError: () -> Void = {}) -> [[String: Value]] {
            var out: [[String: Value]] = []
            let f = format
            let owner = UInt32(definitionPage)
            for pageNumber in 0..<db.pageCount {
                guard let p = db.page(pageNumber), p[p.startIndex] == 0x01, le32(Array(p.prefix(8)), 4) == owner else { continue }
                let page = Array(p)
                let rowCount = Int(le16(page, f.numRowsOnDataPage))
                for rowNumber in 0..<rowCount {
                    let slot = f.rowStart + 2 * rowNumber
                    guard slot + 2 <= page.count else { break }
                    let raw = le16(page, slot)
                    if raw & 0x8000 != 0 { continue }                       // deleted
                    var rowBytes: [UInt8]
                    if raw & 0x4000 != 0 {                                     // overflow: pointer to the real row
                        let start = Int(raw & 0x1FFF)
                        guard start + 4 <= page.count else { onError(); continue }
                        guard let resolved = followOverflow(row: Int(page[start]), page: Int(page[start + 1]) | Int(page[start + 2]) << 8 | Int(page[start + 3]) << 16) else { onError(); continue }
                        rowBytes = resolved
                    } else {
                        let start = Int(raw & 0x1FFF)
                        let end = rowNumber == 0 ? f.pageSize : Int(le16(page, slot - 2) & 0x1FFF)
                        guard start <= end, end <= page.count else { onError(); continue }
                        rowBytes = Array(page[start..<end])
                    }
                    do { out.append(try decode(row: rowBytes)) } catch { onError() }
                }
            }
            return out
        }

        private func followOverflow(row: Int, page pageNumber: Int) -> [UInt8]? {
            var row = row, pageNumber = pageNumber
            var visited: Set<Int> = []
            while visited.insert(pageNumber << 8 | row).inserted {
                guard let p = db.page(pageNumber), p[p.startIndex] == 0x01 else { return nil }
                let page = Array(p)
                let slot = format.rowStart + 2 * row
                guard slot + 2 <= page.count else { return nil }
                let raw = le16(page, slot)
                let start = Int(raw & 0x1FFF)
                let end = row == 0 ? format.pageSize : Int(le16(page, slot - 2) & 0x1FFF)
                guard start <= end, end <= page.count else { return nil }
                if raw & 0x4000 != 0 {
                    guard start + 4 <= page.count else { return nil }
                    row = Int(page[start]); pageNumber = Int(page[start + 1]) | Int(page[start + 2]) << 8 | Int(page[start + 3]) << 16
                    continue
                }
                return Array(page[start..<end])
            }
            return nil
        }

        /// One row's values by lowercased column name (Jackcess getRowColumn).
        func decode(row r: [UInt8]) throws -> [String: Value] {
            let f = format
            guard r.count >= f.sizeRowColumnCount + 1 else { throw Issue("row too short") }
            let columnCount = f.sizeRowColumnCount == 1 ? Int(r[0]) : Int(le16(r, 0))
            let nullMaskSize = (columnCount + 7) / 8
            guard nullMaskSize <= r.count else { throw Issue("null mask larger than the row") }
            let nullMask = Array(r[(r.count - nullMaskSize)...])
            var jumpOffsets: [Int]?
            var values: [String: Value] = [:]
            for column in columns {
                let present = column.number < columnCount && (nullMask[column.number / 8] & (1 << (column.number % 8))) != 0
                if column.type == 0x01 { values[column.name.lowercased()] = .bool(present); continue }
                guard present else { continue }
                let start: Int, end: Int
                if !column.isVariable {
                    start = f.fixedDataRowOffset + column.fixedOffset
                    end = start + fixedSize(column)
                } else if !f.jet3 {
                    let offsetPos = (r.count - nullMaskSize - 4) - column.varIndex * 2
                    guard offsetPos >= 2, offsetPos + 2 <= r.count else { throw Issue("variable offset table outside the row") }
                    start = Int(le16(r, offsetPos)); end = Int(le16(r, offsetPos - 2))
                } else {
                    if jumpOffsets == nil { jumpOffsets = try jumpTable(r, nullMaskSize: nullMaskSize) }
                    guard let table = jumpOffsets, column.varIndex + 1 < table.count else { throw Issue("variable column index outside the jump table") }
                    start = table[column.varIndex]; end = table[column.varIndex + 1]
                }
                guard start >= 0, start <= end, end <= r.count else { continue }
                let data = Array(r[start..<end])
                if let value = try value(of: column, data: data) { values[column.name.lowercased()] = value }
            }
            return values
        }

        /// Jet 3 variable-column offsets (Jackcess readJumpTableVarColOffsets).
        private func jumpTable(_ r: [UInt8], nullMaskSize: Int) throws -> [Int] {
            let rowEnd = r.count - 1
            guard rowEnd - nullMaskSize >= 0 else { throw Issue("row too short for a jump table") }
            let numVarCols = Int(r[rowEnd - nullMaskSize])
            let rowLen = r.count
            var numJumps = (rowLen - 1) / 255
            let colOffset = rowEnd - nullMaskSize - numJumps - 1
            if (colOffset - numVarCols) / 255 < numJumps { numJumps -= 1 }
            var offsets: [Int] = []
            var jumpsUsed = 0
            for i in 0...numVarCols {
                while jumpsUsed < numJumps, rowEnd - nullMaskSize - jumpsUsed - 1 >= 0, i == Int(r[rowEnd - nullMaskSize - jumpsUsed - 1]) { jumpsUsed += 1 }
                guard colOffset - i >= 0 else { throw Issue("jump table outside the row") }
                offsets.append(Int(r[colOffset - i]) + jumpsUsed * 255)
            }
            return offsets
        }

        private func fixedSize(_ c: Column) -> Int {
            switch c.type {
            case 0x02: return 1
            case 0x03: return 2
            case 0x04, 0x06, 0x12: return 4
            case 0x05, 0x07, 0x08, 0x13: return 8
            case 0x0F: return 16
            case 0x10: return 17
            case 0x14: return 42
            default: return c.length
            }
        }

        private func value(of column: Column, data: [UInt8]) throws -> Value? {
            switch column.type {
            case 0x02: return data.count >= 1 ? .int(Int(data[0])) : nil
            case 0x03: return data.count >= 2 ? .int(Int(Int16(bitPattern: le16(data, 0)))) : nil
            case 0x04: return data.count >= 4 ? .int(Int(Int32(bitPattern: le32(data, 0)))) : nil
            case 0x13: return data.count >= 8 ? .int(Int(Int64(bitPattern: le64(data, 0)))) : nil
            case 0x05:
                guard data.count >= 8 else { return nil }
                return .decimal(AccessTextExtractor.scaled(Int64(bitPattern: le64(data, 0)), scale: 4))
            case 0x06:
                guard data.count >= 4 else { return nil }
                return .double(Double(Float(bitPattern: le32(data, 0))))
            case 0x07:
                guard data.count >= 8 else { return nil }
                return .double(Double(bitPattern: le64(data, 0)))
            case 0x08:
                guard data.count >= 8 else { return nil }
                return .date(AccessTextExtractor.dateString(Double(bitPattern: le64(data, 0))))
            case 0x0A: return .text(decodeText(data))
            case 0x0C:
                guard let bytes = try longValue(data) else { return nil }
                return .text(decodeText(bytes))
            case 0x0B: return .ole
            case 0x09, 0x11: return .binary("binary")
            case 0x0F: return .binary("GUID")
            case 0x10:
                guard data.count >= 17 else { return nil }
                return .decimal(AccessTextExtractor.numeric(data, scale: column.scale))
            case 0x12: return .binary("attachment or multi-value field")
            case 0x14:
                guard data.count >= 32 else { return nil }
                return .date(String(bytes: data.prefix(32), encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "")
            default: return nil
            }
        }

        /// LVAL: inline (0x80), on one other page (0x40) or a chain of pages (0x00).
        private func longValue(_ def: [UInt8]) throws -> [UInt8]? {
            guard def.count >= 4 else { return nil }
            let lengthWithFlags = le32(def, 0)
            let length = Int(lengthWithFlags & 0x3FFF_FFFF)
            let type = UInt8((lengthWithFlags & 0xC000_0000) >> 24)
            if type == 0x80 {
                guard def.count >= 12 else { return nil }
                return Array(def[12..<min(def.count, 12 + length)])
            }
            guard def.count >= format.sizeLongValueDef else { throw Issue("long value definition is \(def.count) bytes, not \(format.sizeLongValueDef)") }
            var row = Int(def[4]), pageNumber = Int(def[5]) | Int(def[6]) << 8 | Int(def[7]) << 16
            func slice(row: Int, page pageNumber: Int) throws -> [UInt8] {
                guard let p = db.page(pageNumber) else { throw Issue("long value page \(pageNumber) is outside the file") }
                let page = Array(p)
                let slot = format.rowStart + 2 * row
                guard slot + 2 <= page.count else { throw Issue("long value row \(row) outside page \(pageNumber)") }
                let start = Int(le16(page, slot) & 0x1FFF)
                let end = row == 0 ? format.pageSize : Int(le16(page, slot - 2) & 0x1FFF)
                guard start <= end, end <= page.count else { throw Issue("long value row bounds are inverted") }
                return Array(page[start..<end])
            }
            if type == 0x40 {
                let bytes = try slice(row: row, page: pageNumber)
                return Array(bytes.prefix(length))
            }
            var out: [UInt8] = []
            var remaining = length
            var visited: Set<Int> = []
            while remaining > 0 {
                guard visited.insert(pageNumber << 8 | row).inserted else { throw Issue("long value chain loops") }
                let bytes = try slice(row: row, page: pageNumber)
                guard bytes.count >= 4 else { throw Issue("long value chunk shorter than its pointer") }
                row = Int(bytes[0]); pageNumber = Int(bytes[1]) | Int(bytes[2]) << 8 | Int(bytes[3]) << 16
                let chunk = bytes.dropFirst(4).prefix(remaining)
                out.append(contentsOf: chunk)
                remaining -= chunk.count
                if chunk.isEmpty { break }
            }
            return out
        }

        /// Jackcess decodeTextValue: the FF FE scheme toggles compressed (8-bit)
        /// and uncompressed (UTF-16LE) runs on 0x00; otherwise the database's text encoding.
        func decodeText(_ data: [UInt8]) -> String {
            if data.count > 1, data[0] == 0xFF, data[1] == 0xFE {
                var out = ""
                var compressed = true
                var segment: [UInt8] = []
                func flush() {
                    guard !segment.isEmpty else { return }
                    if compressed {
                        var wide: [UInt8] = []
                        wide.reserveCapacity(segment.count * 2)
                        for byte in segment { wide.append(byte); wide.append(0) }
                        out += String(bytes: wide, encoding: .utf16LittleEndian) ?? ""
                    } else {
                        out += String(bytes: segment, encoding: .utf16LittleEndian) ?? ""
                    }
                    segment.removeAll(keepingCapacity: true)
                }
                for byte in data.dropFirst(2) {
                    if byte == 0 { flush(); compressed.toggle() } else { segment.append(byte) }
                }
                flush()
                return out
            }
            return String(bytes: data, encoding: db.textEncoding) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
        }
    }

    // MARK: - Value formatting

    static func formatDouble(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// An integer scaled by 10^scale, as "123.45" with the trailing zeros trimmed.
    static func scaled(_ value: Int64, scale: Int) -> String {
        let negative = value < 0
        var digits = String(value.magnitude)
        while digits.count <= scale { digits = "0" + digits }
        let whole = digits.dropLast(scale), fraction = digits.suffix(scale)
        var text = String(whole)
        let trimmed = fraction.reversed().drop { $0 == "0" }.reversed()
        if !trimmed.isEmpty { text += "." + String(trimmed) }
        return (negative ? "-" : "") + text
    }

    /// NUMERIC: sign byte then a 16-byte unsigned magnitude stored as four
    /// little-endian 32-bit words (Jackcess fixNumericByteOrder).
    static func numeric(_ data: [UInt8], scale: Int) -> String {
        let negative = data[0] != 0
        var magnitude: [UInt8] = []           // big-endian
        for word in 0..<4 {
            let o = 1 + word * 4
            magnitude.append(contentsOf: [data[o + 3], data[o + 2], data[o + 1], data[o]])
        }
        // Repeated division by 10 on the big-endian byte array.
        var digits: [Character] = []
        var current = magnitude
        while current.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in current.indices {
                let v = remainder * 256 + Int(current[i])
                current[i] = UInt8(v / 10)
                remainder = v % 10
            }
            digits.append(Character(String(remainder)))
        }
        if digits.isEmpty { digits = ["0"] }
        var text = String(digits.reversed())
        if scale > 0 {
            while text.count <= scale { text = "0" + text }
            let whole = text.dropLast(scale), fraction = text.suffix(scale)
            let trimmed = fraction.reversed().drop { $0 == "0" }.reversed()
            text = String(whole) + (trimmed.isEmpty ? "" : "." + String(trimmed))
        }
        return (negative ? "-" : "") + text
    }

    /// Access dates: days since 1899-12-30, the time as the absolute fraction of a day.
    static func dateString(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 3_000_000 else { return "" }
        let days = Int(value)
        let seconds = Int((abs(value) - abs(value).rounded(.towardZero)) * 86_400 + 0.5)
        let date = Date(timeIntervalSince1970: TimeInterval(days - 25_569) * 86_400 + TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = seconds == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func codePageEncoding(_ codePage: Int) -> String.Encoding {
        switch codePage {
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 932: return .shiftJIS
        case 1200: return .utf16LittleEndian
        case 65001: return .utf8
        default: return .windowsCP1252
        }
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
}

private func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
private func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
private func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }
