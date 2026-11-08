//
//  XLSBFormulaDecoder.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Excel/XLSB": the formula of a BrtFmlaNum /
//  BrtFmlaStr / BrtFmlaBool / BrtFmlaError cell is a parsed token stream
//  (MS-XLSB §2.5.97, "Ptg"), not text. This decoder renders it back to A1
//  formula text without evaluating anything:
//
//    operands   PtgInt, PtgNum, PtgStr, PtgBool, PtgErr, PtgMissArg, PtgArray
//    references PtgRef, PtgArea, PtgRefN, PtgAreaN (relative to the cell),
//               PtgRef3d, PtgArea3d (sheet names through the XTI table),
//               the *Err forms as #REF!, PtgName, PtgNameX (the external
//               workbook's BrtSupNameStart names, an add-in's
//               BrtPlaceholderName functions)
//    tables     PtgList (0x18 0x19, [MS-XLSB] 2.5.98.52): a structured
//               reference rendered as Excel shows it — Table1[Column],
//               Table1[[#Headers],[Column]], Table1[#All], Table1[] — with the
//               table and column names from the table parts (BrtBeginList,
//               BrtBeginListCol); "#This Row" as [@Column] inside the table
//               and Table1[@Column] outside it; a table in another workbook
//               from its PtgExtraList; an invalid one as #REF!
//    PivotTable PtgSxName (0x18 0x1D) — only in PivotTable cache formulas,
//               which are not read; named by its index
//    operators  + - * / ^ & = < <= > >= <> and the range (:), union (,) and
//               intersection ( ) operators, unary + - %, parentheses
//    functions  PtgFunc (fixed argument count) and PtgFuncVar from the
//               Ftab, or the Cetab when fCeFunc is set (macro-sheet commands)
//               — every documented id is named (XLSBFunctionTables.swift);
//               id 255 is a user-defined, add-in or future function whose
//               name is the first operand: "_xlfn." / "_xlws." prefixes are
//               dropped (XLOOKUP, SORT), _xlfn.SINGLE renders as @x and
//               _xlfn.ANCHORARRAY as A1#, LAMBDA/LET parameters lose "_xlpm."
//    control    PtgAttr (SUM shorthand, IF/CHOOSE jump tables, spaces,
//               volatile markers — the text keeps no extra spacing),
//               PtgMemArea/Err/NoMem/Func (the reference subexpression that
//               follows is rendered; PtgMemArea's PtgExtraMem is consumed)
//    shared     PtgExp (row, and the column in its PtgExtraCol) points at the
//               BrtShrFmla / BrtArrFmla whose range holds the cell; the
//               caller re-decodes that record with this cell as the base
//
//  [MS-XLSB] has no natural-language tokens (the BIFF8 PtgElf* family of
//  [MS-XLS] does not exist in the binary workbook format): 0x18 carries only
//  PtgList and PtgSxName, 0x19 only the PtgAttr family.
//
//  A token this decoder does not know ends the rendering with
//  "(formula not decoded: token 0xNN)" — nothing is silently dropped. A
//  function id outside the tables renders as "(function N not decoded)".
//

import Foundation

struct XLSBFormulaContext: Sendable {
    enum SupBook: Sendable, Equatable {
        /// This workbook's own sheets.
        case selfBook
        /// A sheet-less reference back into the same workbook (BrtSupSame).
        case sameSheet
        /// Another workbook: its target when the externalLink part named it, its sheet tabs.
        case external(target: String?, tabs: [String])
        /// An add-in (BrtSupAddin) — function names only.
        case addIn
    }

    /// Sheet names in BrtBundleSh order (itab).
    var sheetNames: [String] = []
    /// BrtExternSheet entries: (iSupBook, itabFirst, itabLast); -1 = #REF!, -2 = workbook-level.
    var externSheets: [(supBook: Int, first: Int, last: Int)] = []
    var supBooks: [SupBook] = []
    /// Defined names in BrtName order (PtgName.nameindex is 1-based).
    var definedNames: [String] = []
    /// Per supporting link (index into `supBooks`): the external workbook's defined names in
    /// BrtSupNameStart order, or an add-in's function names in BrtPlaceholderName order
    /// (PtgNameX.nameindex is 1-based).
    var supNames: [Int: [String]] = [:]

    /// A table (BrtBeginList) and its columns (BrtBeginListCol captions, in column order).
    struct Table: Sendable {
        let id: Int
        let name: String
        let columns: [String]
        let rowFirst: Int, rowLast: Int, columnFirst: Int, columnLast: Int
        func contains(row: Int, column: Int) -> Bool { row >= rowFirst && row <= rowLast && column >= columnFirst && column <= columnLast }
    }
    /// Tables by idList (PtgList.listIndex).
    var tables: [Int: Table] = [:]

    /// PtgNameX: the external or add-in name, with the workbook prefix for an external one.
    func externalName(xti: Int, index: Int) -> String? {
        guard xti >= 0, xti < externSheets.count else { return nil }
        let supBook = externSheets[xti].supBook
        guard let names = supNames[supBook], index >= 1, index <= names.count else { return nil }
        let name = names[index - 1]
        if supBook >= 0, supBook < supBooks.count, case .external = supBooks[supBook] { return sheetPrefix(xti: xti) + name }
        return name
    }

    /// The sheet prefix for an XTI index ("Sheet1!", "'My Sheet'!", "Sheet1:Sheet3!", "[Budget.xlsx]Q1!").
    func sheetPrefix(xti: Int) -> String {
        guard xti >= 0, xti < externSheets.count else { return "#REF!" }
        let entry = externSheets[xti]
        let book: SupBook = entry.supBook >= 0 && entry.supBook < supBooks.count ? supBooks[entry.supBook] : .selfBook
        var names: [String]
        var prefix = ""
        switch book {
        case .selfBook, .sameSheet: names = sheetNames
        case .external(let target, let tabs): names = tabs; prefix = "[" + (target ?? "external workbook \(entry.supBook + 1)") + "]"
        case .addIn: return ""
        }
        func name(_ index: Int) -> String {
            if index == -1 { return "#REF!" }
            if index == -2 { return "" }
            return index >= 0 && index < names.count ? names[index] : "#REF!"
        }
        let first = name(entry.first)
        let last = name(entry.last)
        if first.isEmpty && last.isEmpty { return prefix.isEmpty ? "" : prefix + "!" }
        let span = first == last ? first : first + ":" + last
        return quoteSheet(prefix + span) + "!"
    }

    private func quoteSheet(_ name: String) -> String {
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "[" || $0 == "]" || $0 == ":" || $0 == "#" || $0 == "!" }
        return plain && !name.isEmpty ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

enum XLSBFormulaDecoder {

    /// A cell position for relative tokens (zero-based).
    struct Base: Sendable { let row: Int; let column: Int }

    /// The rendered formula text (without the leading "=").
    static func decode(rgce: Data, rgcb: Data, base: Base?, context: XLSBFormulaContext) -> String {
        var decoder = Decoder(rgce: Array(rgce), rgcb: Array(rgcb), base: base, context: context)
        return decoder.run()
    }

    /// PtgExp inside a cell formula: the row/column of the shared or array formula's master cell.
    /// [MS-XLSB] 2.5.98.40: the token holds only the row (4 bytes); the column is the PtgExtraCol
    /// (4 bytes) in rgcb — that is what Excel writes. A 2-byte column straight after the row
    /// (the BIFF8 shape) is still accepted.
    static func sharedFormulaMaster(rgce: Data, rgcb: Data = Data()) -> (row: Int, column: Int)? {
        let bytes = Array(rgce)
        guard bytes.count >= 5, bytes[0] & 0x7F == 0x01 else { return nil }
        let row = Int(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24)
        if bytes.count >= 7 { return (row, Int(UInt16(bytes[5]) | UInt16(bytes[6]) << 8)) }
        let extra = Array(rgcb)
        guard extra.count >= 4 else { return (row, -1) }
        return (row, Int(UInt32(extra[0]) | UInt32(extra[1]) << 8 | UInt32(extra[2]) << 16 | UInt32(extra[3]) << 24))
    }

    private struct Decoder {
        let rgce: [UInt8]
        let rgcb: [UInt8]
        let base: Base?
        let context: XLSBFormulaContext
        var pos = 0
        var extraPos = 0
        var stack: [String] = []

        init(rgce: [UInt8], rgcb: [UInt8], base: Base?, context: XLSBFormulaContext) {
            self.rgce = rgce; self.rgcb = rgcb; self.base = base; self.context = context
        }

        mutating func run() -> String {
            if rgce.isEmpty { return "" }
            while pos < rgce.count {
                let ptg = rgce[pos]; pos += 1
                let baseToken = ptg >= 0x20 && ptg < 0x80 ? (ptg & 0x1F) | 0x20 : ptg
                if let failure = step(ptg: ptg, token: baseToken) {
                    let partial = stack.joined(separator: " ")
                    return (partial.isEmpty ? "" : partial + " ") + failure
                }
            }
            if stack.count == 1 { return stack[0] }
            if stack.isEmpty { return "(formula not decoded: no operands)" }
            return stack.joined(separator: " ") + " (formula not decoded: \(stack.count) operands left)"
        }

        // MARK: Reading

        mutating func u8() -> UInt8? { guard pos < rgce.count else { return nil }; defer { pos += 1 }; return rgce[pos] }
        mutating func u16() -> Int? { guard pos + 2 <= rgce.count else { return nil }; defer { pos += 2 }; return Int(rgce[pos]) | Int(rgce[pos + 1]) << 8 }
        mutating func u32() -> Int? {
            guard pos + 4 <= rgce.count else { return nil }
            defer { pos += 4 }
            return Int(UInt32(rgce[pos]) | UInt32(rgce[pos + 1]) << 8 | UInt32(rgce[pos + 2]) << 16 | UInt32(rgce[pos + 3]) << 24)
        }
        mutating func f64() -> Double? {
            guard pos + 8 <= rgce.count else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(rgce[pos + i]) << (UInt64(i) * 8) }
            pos += 8
            return Double(bitPattern: bits)
        }
        mutating func skip(_ n: Int) -> Bool { guard pos + n <= rgce.count else { return false }; pos += n; return true }
        mutating func string16() -> String? {
            guard let count = u16(), pos + count * 2 <= rgce.count else { return nil }
            let data = Data(rgce[pos..<(pos + count * 2)]); pos += count * 2
            return String(data: data, encoding: .utf16LittleEndian)
        }

        mutating func binary(_ op: String) -> String? {
            guard stack.count >= 2 else { return "(formula not decoded: operator \(op) without two operands)" }
            let b = stack.removeLast(); let a = stack.removeLast()
            stack.append(a + op + b)
            return nil
        }

        mutating func unary(prefix: String = "", suffix: String = "") -> String? {
            guard !stack.isEmpty else { return "(formula not decoded: operator \(prefix)\(suffix) without an operand)" }
            let a = stack.removeLast()
            stack.append(prefix + a + suffix)
            return nil
        }

        // MARK: References

        /// RgceLoc: row (4 bytes), column (14 bits) + fColRel (bit 14) + fRowRel (bit 15).
        mutating func location(relative: Bool) -> String? {
            guard let rawRow = u32(), let colWord = u16() else { return nil }
            let rowRel = colWord & 0x8000 != 0
            let colRel = colWord & 0x4000 != 0
            var col = colWord & 0x3FFF
            var row = rawRow
            if relative {
                // RgceLocRel: offsets in two's complement when the part is relative.
                if colRel { if col >= 0x2000 { col -= 0x4000 } }
                if rowRel { row = Int(Int32(truncatingIfNeeded: UInt32(rawRow))) }
                if let base {
                    if colRel { col += base.column }
                    if rowRel { row += base.row }
                } else {
                    // No cell to anchor to (a defined name): R1C1 offsets say exactly what is stored.
                    let r = rowRel ? "R[\(row)]" : "R\(row + 1)"
                    let c = colRel ? "C[\(col)]" : "C\(col + 1)"
                    return r + c
                }
            }
            guard row >= 0, row < ExcelFormulaText.maxRow, col >= 0, col < ExcelFormulaText.maxColumn else { return "#REF!" }
            return (colRel ? "" : "$") + OfficeTextExtractor.columnName(col) + (rowRel ? "" : "$") + String(row + 1)
        }

        /// RgceArea: rowFirst, rowLast (4 bytes each), colFirst, colLast (2 bytes each with the relative bits).
        mutating func area(relative: Bool) -> String? {
            guard let rowFirstRaw = u32(), let rowLastRaw = u32(), let colFirstWord = u16(), let colLastWord = u16() else { return nil }
            func corner(_ rowRaw: Int, _ colWord: Int) -> String {
                let rowRel = colWord & 0x8000 != 0, colRel = colWord & 0x4000 != 0
                var col = colWord & 0x3FFF
                var row = rowRaw
                if relative {
                    if colRel, col >= 0x2000 { col -= 0x4000 }
                    if rowRel { row = Int(Int32(truncatingIfNeeded: UInt32(rowRaw))) }
                    if let base {
                        if colRel { col += base.column }
                        if rowRel { row += base.row }
                    } else {
                        return (rowRel ? "R[\(row)]" : "R\(row + 1)") + (colRel ? "C[\(col)]" : "C\(col + 1)")
                    }
                }
                guard row >= 0, row < ExcelFormulaText.maxRow, col >= 0, col < ExcelFormulaText.maxColumn else { return "#REF!" }
                return (colRel ? "" : "$") + OfficeTextExtractor.columnName(col) + (rowRel ? "" : "$") + String(row + 1)
            }
            return corner(rowFirstRaw, colFirstWord) + ":" + corner(rowLastRaw, colLastWord)
        }

        func name(_ index: Int) -> String {
            guard index >= 1 && index <= context.definedNames.count else { return "(name \(index) not found)" }
            let stored = context.definedNames[index - 1]
            // A LAMBDA / LET parameter is stored as "_xlpm.x"; Excel shows "x".
            return stored.hasPrefix("_xlpm.") ? String(stored.dropFirst(6)) : stored
        }

        /// The name Excel shows for the callee of a user-defined / future function call:
        /// "_xlfn._xlws.SORT" → "SORT", "_xlfn.XLOOKUP" → "XLOOKUP"; an add-in or VBA name as stored.
        static func functionName(_ stored: String) -> String {
            var name = stored
            for prefix in ["_xlfn.", "_xlws."] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
            return name
        }

        /// The next 4-byte value in rgcb (RgbExtra), in token order.
        mutating func extraU32() -> Int? {
            guard extraPos + 4 <= rgcb.count else { return nil }
            defer { extraPos += 4 }
            return Int(UInt32(rgcb[extraPos]) | UInt32(rgcb[extraPos + 1]) << 8 | UInt32(rgcb[extraPos + 2]) << 16 | UInt32(rgcb[extraPos + 3]) << 24)
        }

        // MARK: Structured references

        /// PtgList ([MS-XLSB] 2.5.98.52) after ptg 0x18 and eptg 0x19: ixti (2), a 16-bit word
        /// (columns 2 bits, rowType 5, squareBracketSpace, commaSpace, unused, type 2, invalid,
        /// nonresident, reserved 2), listIndex (4), colFirst (2), colLast (2).
        mutating func list() -> String? {
            guard let xti = u16(), let flags = u16(), let listIndex = u32(), let colFirst = u16(), let colLast = u16() else {
                return "(formula not decoded: token 0x18 0x19 truncated)"
            }
            let columnsKind = flags & 0x3
            var rowType = (flags >> 2) & 0x1F
            let bracketSpace = flags & 0x80 != 0
            let commaSpace = flags & 0x100 != 0
            let invalid = flags & 0x1000 != 0
            let nonresident = flags & 0x2000 != 0
            if invalid { stack.append("#REF!"); return nil }
            var tableName: String
            var columnNames: [String] = []   // the columns this reference names (none = every column)
            var insideTable = false
            if nonresident {
                // PtgExtraList in rgcb: hasColumns (1), rowType (5 bits of 2 bytes), cch (2), table, then SxSu when hasColumns.
                guard extraPos + 5 <= rgcb.count else { return "(formula not decoded: table reference in another workbook without its PtgExtraList)" }
                let hasColumns = rgcb[extraPos] != 0
                rowType = Int(rgcb[extraPos + 1]) & 0x1F
                let cch = Int(rgcb[extraPos + 3]) | Int(rgcb[extraPos + 4]) << 8
                extraPos += 5
                guard let name = extraString(cch) else { return "(formula not decoded: PtgExtraList truncated)" }
                tableName = name
                if hasColumns {
                    // SxSu: reserved (2), csxos (1), then one or two SxOs: notLast (1), reserved (2), LPWideString (cch 2 + UTF-16).
                    guard extraPos + 3 <= rgcb.count else { return "(formula not decoded: PtgExtraList truncated)" }
                    let count = Int(rgcb[extraPos + 2]); extraPos += 3
                    for _ in 0..<min(count, 2) {
                        guard extraPos + 5 <= rgcb.count else { return "(formula not decoded: PtgExtraList truncated)" }
                        let cch = Int(rgcb[extraPos + 3]) | Int(rgcb[extraPos + 4]) << 8
                        extraPos += 5
                        guard let column = extraString(cch) else { return "(formula not decoded: PtgExtraList truncated)" }
                        columnNames.append(column)
                    }
                }
                // Excel writes a table in another workbook as Book.xlsx!Table[…].
                if xti >= 0, xti < context.externSheets.count {
                    let supBook = context.externSheets[xti].supBook
                    if supBook >= 0, supBook < context.supBooks.count, case .external(let target, _) = context.supBooks[supBook] {
                        let book = target ?? "external workbook \(supBook + 1)"
                        let plain = book.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                        tableName = (plain ? book : "'" + book.replacingOccurrences(of: "'", with: "''") + "'") + "!" + tableName
                    }
                }
            } else {
                guard let table = context.tables[listIndex] else { return "(table \(listIndex) not found)" }
                tableName = table.name
                if columnsKind != 0 {
                    let last = columnsKind == 2 ? colLast : colFirst
                    guard colFirst >= 0, colFirst < table.columns.count, last >= colFirst, last < table.columns.count else { return tableName + "[#REF!]" }
                    columnNames = [table.columns[colFirst]] + (last > colFirst ? [table.columns[last]] : [])
                }
                if let base { insideTable = table.contains(row: base.row, column: base.column) }
            }
            stack.append(Self.structuredReference(table: tableName, rowType: rowType, columns: columnNames,
                                                  insideTable: insideTable, bracketSpace: bracketSpace, commaSpace: commaSpace))
            return nil
        }

        mutating func extraString(_ cch: Int) -> String? {
            guard cch >= 0, extraPos + cch * 2 <= rgcb.count else { return nil }
            defer { extraPos += cch * 2 }
            return String(data: Data(rgcb[extraPos..<(extraPos + cch * 2)]), encoding: .utf16LittleEndian)
        }

        /// Excel's text for a structured reference (PtgRowType [MS-XLSB] 2.5.98.73 → item specifiers).
        static func structuredReference(table: String, rowType: Int, columns: [String], insideTable: Bool,
                                        bracketSpace: Bool, commaSpace: Bool) -> String {
            /// A column name inside brackets: [ ] # ' are escaped with a leading apostrophe.
            func escaped(_ name: String) -> String {
                var out = ""
                for character in name { if "[]#'".contains(character) { out.append("'") }; out.append(character) }
                return out
            }
            let columnPart: String? = columns.isEmpty ? nil : columns.map { "[" + escaped($0) + "]" }.joined(separator: ":")
            let open = bracketSpace ? "[ " : "[", close = bracketSpace ? " ]" : "]"
            let comma = commaSpace ? ", " : ","
            if rowType == 0x10 {   // CURRENT: "#This Row", shown with @ since Excel 2010
                var body = "@"
                if columns.count == 1 {
                    let name = columns[0]
                    let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                    body += plain ? name : "[" + escaped(name) + "]"
                } else if let columnPart {
                    body += "[" + columnPart + "]"
                }
                return (insideTable ? "" : table) + "[" + body + "]"
            }
            let keywords: [String]
            switch rowType {
            case 0x01: keywords = ["#All"]
            case 0x02: keywords = ["#Headers"]
            case 0x04: keywords = ["#Data"]
            case 0x06: keywords = ["#Headers", "#Data"]
            case 0x08: keywords = ["#Totals"]
            case 0x0C: keywords = ["#Data", "#Totals"]
            default:   keywords = []   // DATA (0): the data region, Excel writes no keyword
            }
            if keywords.isEmpty {
                guard let columnPart else { return table + "[]" }
                // One column: Table1[Column]; a column range keeps its own brackets: Table1[[A]:[C]].
                return table + (columns.count == 1 ? columnPart : open + columnPart + close)
            }
            if keywords.count == 1 && columnPart == nil { return table + "[" + keywords[0] + "]" }
            let items = keywords.map { "[" + $0 + "]" } + (columnPart.map { [$0] } ?? [])
            return table + open + items.joined(separator: comma) + close
        }

        // MARK: Tokens

        /// Returns a failure text, or nil when the token was consumed.
        mutating func step(ptg: UInt8, token: UInt8) -> String? {
            switch token {
            case 0x01:   // PtgExp — the caller resolves shared/array formulas before decoding; seen here it is a reference to a master cell
                guard let row = u32() else { return "(formula not decoded: token 0x01 truncated)" }
                let col = extraU32() ?? 0   // PtgExtraCol
                stack.append("(shared formula of \(OfficeTextExtractor.columnName(col))\(row + 1) not resolved)")
                return nil
            case 0x02:   // PtgTbl — data table; the cell holds a what-if result
                guard skip(6) else { return "(formula not decoded: token 0x02 truncated)" }
                stack.append("TABLE()")
                return nil
            case 0x03: return binary("+")
            case 0x04: return binary("-")
            case 0x05: return binary("*")
            case 0x06: return binary("/")
            case 0x07: return binary("^")
            case 0x08: return binary("&")
            case 0x09: return binary("<")
            case 0x0A: return binary("<=")
            case 0x0B: return binary("=")
            case 0x0C: return binary(">=")
            case 0x0D: return binary(">")
            case 0x0E: return binary("<>")
            case 0x0F: return binary(" ")     // intersection
            case 0x10: return binary(",")     // union
            case 0x11: return binary(":")     // range
            case 0x12: return unary(prefix: "+")
            case 0x13: return unary(prefix: "-")
            case 0x14: return unary(suffix: "%")
            case 0x15: return unary(prefix: "(", suffix: ")")
            case 0x16: stack.append(""); return nil               // PtgMissArg
            case 0x17:
                guard let text = string16() else { return "(formula not decoded: token 0x17 truncated)" }
                stack.append("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                return nil
            case 0x18:   // extended operands: PtgList (table reference) and PtgSxName
                guard let eptg = u8() else { return "(formula not decoded: token 0x18 truncated)" }
                switch eptg {
                case 0x19: return list()
                case 0x1D:
                    guard let index = u32() else { return "(formula not decoded: token 0x18 0x1D truncated)" }
                    stack.append("(PivotTable calculated name \(index + 1))"); return nil
                default: return String(format: "(formula not decoded: token 0x18 0x%02X)", eptg)
                }
            case 0x19: return attribute()
            case 0x1C:
                guard let code = u8() else { return "(formula not decoded: token 0x1C truncated)" }
                stack.append(XLSBReader.errorName(code)); return nil
            case 0x1D:
                guard let flag = u8() else { return "(formula not decoded: token 0x1D truncated)" }
                stack.append(flag == 0 ? "FALSE" : "TRUE"); return nil
            case 0x1E:
                guard let value = u16() else { return "(formula not decoded: token 0x1E truncated)" }
                stack.append(String(value)); return nil
            case 0x1F:
                guard let value = f64() else { return "(formula not decoded: token 0x1F truncated)" }
                stack.append(XLSBReader.number(value)); return nil
            case 0x20:   // PtgArray: 14 unused bytes here, the constants in rgcb
                guard skip(14) else { return "(formula not decoded: token 0x20 truncated)" }
                stack.append(arrayConstant()); return nil
            case 0x21:
                guard let id = u16() else { return "(formula not decoded: token 0x21 truncated)" }
                guard let entry = XLSBFunctionTable.entry(id) else { return "(function \(id) not decoded)" }
                guard let count = entry.fixedArguments else { return "(function \(entry.name) without an argument count)" }
                return call(entry.name, count)
            case 0x22:
                guard let count = u8(), let word = u16() else { return "(formula not decoded: token 0x22 truncated)" }
                let id = word & 0x7FFF
                if word & 0x8000 != 0 {   // fCeFunc: a macro-sheet command (Cetab)
                    guard let command = XLSBFunctionTable.command(id) else { return "(command \(id) not decoded)" }
                    return call(command, Int(count))
                }
                if id == 255 {   // user-defined / add-in / future function: the name is the first argument
                    guard stack.count >= Int(count), count >= 1 else { return "(formula not decoded: user function without its name)" }
                    let arguments = Array(stack.suffix(Int(count) - 1)); stack.removeLast(Int(count) - 1)
                    let functionName = Self.functionName(stack.removeLast())
                    // Dynamic-array markers Excel shows as operators: =@A1:A3 and =A1#.
                    if functionName == "SINGLE", arguments.count == 1 { stack.append("@" + arguments[0]); return nil }
                    if functionName == "ANCHORARRAY", arguments.count == 1 { stack.append(arguments[0] + "#"); return nil }
                    stack.append(functionName + "(" + arguments.joined(separator: ",") + ")")
                    return nil
                }
                guard let entry = XLSBFunctionTable.entry(id) else { return "(function \(id) not decoded)" }
                return call(entry.name, Int(count))
            case 0x23:
                guard let index = u32() else { return "(formula not decoded: token 0x23 truncated)" }
                stack.append(name(index)); return nil
            case 0x24:
                guard let text = location(relative: false) else { return "(formula not decoded: token 0x24 truncated)" }
                stack.append(text); return nil
            case 0x25:
                guard let text = area(relative: false) else { return "(formula not decoded: token 0x25 truncated)" }
                stack.append(text); return nil
            case 0x26, 0x27, 0x28:   // PtgMemArea / PtgMemErr / PtgMemNoMem: 4 unused bytes + cce; the subexpression follows
                guard skip(6) else { return "(formula not decoded: token 0x\(String(ptg, radix: 16, uppercase: true)) truncated)" }
                if token == 0x26, let count = extraU32() { extraPos += min(count, 1 << 20) * 16 }   // PtgExtraMem: count UncheckedRfX
                return nil
            case 0x29:               // PtgMemFunc: cce only
                guard skip(2) else { return "(formula not decoded: token 0x29 truncated)" }
                return nil
            case 0x2A:
                guard skip(6) else { return "(formula not decoded: token 0x2A truncated)" }
                stack.append("#REF!"); return nil
            case 0x2B:
                guard skip(12) else { return "(formula not decoded: token 0x2B truncated)" }
                stack.append("#REF!"); return nil
            case 0x2C:
                guard let text = location(relative: true) else { return "(formula not decoded: token 0x2C truncated)" }
                stack.append(text); return nil
            case 0x2D:
                guard let text = area(relative: true) else { return "(formula not decoded: token 0x2D truncated)" }
                stack.append(text); return nil
            case 0x39:
                guard let xti = u16(), let index = u32() else { return "(formula not decoded: token 0x39 truncated)" }
                if let external = context.externalName(xti: xti, index: index) { stack.append(external); return nil }
                let prefix = context.sheetPrefix(xti: xti)
                stack.append((prefix == "#REF!" ? "" : prefix) + name(index)); return nil
            case 0x3A:
                guard let xti = u16(), let text = location(relative: false) else { return "(formula not decoded: token 0x3A truncated)" }
                stack.append(context.sheetPrefix(xti: xti) + text); return nil
            case 0x3B:
                guard let xti = u16(), let text = area(relative: false) else { return "(formula not decoded: token 0x3B truncated)" }
                stack.append(context.sheetPrefix(xti: xti) + text); return nil
            case 0x3C:
                guard let xti = u16(), skip(6) else { return "(formula not decoded: token 0x3C truncated)" }
                stack.append(context.sheetPrefix(xti: xti) + "#REF!"); return nil
            case 0x3D:
                guard let xti = u16(), skip(12) else { return "(formula not decoded: token 0x3D truncated)" }
                stack.append(context.sheetPrefix(xti: xti) + "#REF!"); return nil
            default:
                return String(format: "(formula not decoded: token 0x%02X)", ptg)
            }
        }

        mutating func call(_ functionName: String, _ count: Int) -> String? {
            guard stack.count >= count else { return "(formula not decoded: \(functionName) needs \(count) arguments, \(stack.count) given)" }
            let arguments = Array(stack.suffix(count)); stack.removeLast(count)
            stack.append(functionName + "(" + arguments.joined(separator: ",") + ")")
            return nil
        }

        /// PtgAttr: control tokens that leave the text unchanged except AttrSum (the SUM shorthand).
        mutating func attribute() -> String? {
            guard let kind = u8() else { return "(formula not decoded: token 0x19 truncated)" }
            switch kind {
            case 0x01, 0x02, 0x08, 0x20, 0x21, 0x40, 0x41, 0x80:   // semi, if, goto, baxcel, space, iferror: 2 bytes
                return skip(2) ? nil : "(formula not decoded: token 0x19 0x\(String(kind, radix: 16)) truncated)"
            case 0x04:                                              // choose: cOffset + (cOffset + 1) jump words
                guard let count = u16(), skip((count + 1) * 2) else { return "(formula not decoded: token 0x19 0x04 truncated)" }
                return nil
            case 0x10:
                guard skip(2) else { return "(formula not decoded: token 0x19 0x10 truncated)" }
                return call("SUM", 1)
            default:
                return String(format: "(formula not decoded: token 0x19 0x%02X)", kind)
            }
        }

        /// PtgExtraArray in rgcb: cols (4), rows (4), then rows×cols SerAr values.
        mutating func arrayConstant() -> String {
            func u32x() -> Int? {
                guard extraPos + 4 <= rgcb.count else { return nil }
                defer { extraPos += 4 }
                return Int(UInt32(rgcb[extraPos]) | UInt32(rgcb[extraPos + 1]) << 8 | UInt32(rgcb[extraPos + 2]) << 16 | UInt32(rgcb[extraPos + 3]) << 24)
            }
            guard let cols = u32x(), let rows = u32x(), cols >= 1, rows >= 1, cols * rows <= 1 << 20 else { return "(array constant not decoded)" }
            var lines: [String] = []
            for _ in 0..<rows {
                var cells: [String] = []
                for _ in 0..<cols {
                    guard extraPos < rgcb.count else { return "(array constant not decoded)" }
                    let type = rgcb[extraPos]; extraPos += 1
                    switch type {
                    case 0x00: extraPos += 8; cells.append("")
                    case 0x01:
                        guard extraPos + 8 <= rgcb.count else { return "(array constant not decoded)" }
                        var bits: UInt64 = 0
                        for i in 0..<8 { bits |= UInt64(rgcb[extraPos + i]) << (UInt64(i) * 8) }
                        extraPos += 8
                        cells.append(XLSBReader.number(Double(bitPattern: bits)))
                    case 0x02:
                        guard let count = u32x(), extraPos + count * 2 <= rgcb.count else { return "(array constant not decoded)" }
                        let text = String(data: Data(rgcb[extraPos..<(extraPos + count * 2)]), encoding: .utf16LittleEndian) ?? ""
                        extraPos += count * 2
                        cells.append("\"" + text + "\"")
                    case 0x04:
                        guard extraPos + 8 <= rgcb.count else { return "(array constant not decoded)" }
                        cells.append(rgcb[extraPos] == 0 ? "FALSE" : "TRUE"); extraPos += 8
                    case 0x10:
                        guard extraPos + 8 <= rgcb.count else { return "(array constant not decoded)" }
                        cells.append(XLSBReader.errorName(rgcb[extraPos])); extraPos += 8
                    default: return "(array constant not decoded)"
                    }
                }
                lines.append(cells.joined(separator: ","))
            }
            return "{" + lines.joined(separator: ";") + "}"
        }
    }
}
