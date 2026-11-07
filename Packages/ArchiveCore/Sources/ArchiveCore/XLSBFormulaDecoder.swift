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
//               the *Err forms as #REF!, PtgName, PtgNameX
//    operators  + - * / ^ & = < <= > >= <> and the range (:), union (,) and
//               intersection ( ) operators, unary + - %, parentheses
//    functions  PtgFunc (fixed argument count) and PtgFuncVar from the
//               Excel function table; 255 is a user-defined function whose
//               name is the first argument
//    control    PtgAttr (SUM shorthand, IF/CHOOSE jump tables, spaces,
//               volatile markers — none change the text), PtgMem* (skipped)
//    shared     PtgExp points at the BrtShrFmla / BrtArrFmla whose range
//               holds the cell; the caller re-decodes that record with this
//               cell as the base
//
//  A token this decoder does not know ends the rendering with
//  "(formula not decoded: token 0xNN)" — nothing is silently dropped. A
//  function id outside the table renders as "(function N not decoded)".
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
    static func sharedFormulaMaster(rgce: Data) -> (row: Int, column: Int)? {
        let bytes = Array(rgce)
        guard bytes.count >= 7, bytes[0] & 0x1F == 0x01 else { return nil }
        let row = Int(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24)
        let column = Int(UInt16(bytes[5]) | UInt16(bytes[6]) << 8)
        return (row, column)
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
            index >= 1 && index <= context.definedNames.count ? context.definedNames[index - 1] : "(name \(index) not found)"
        }

        // MARK: Tokens

        /// Returns a failure text, or nil when the token was consumed.
        mutating func step(ptg: UInt8, token: UInt8) -> String? {
            switch token {
            case 0x01:   // PtgExp — the caller resolves shared/array formulas before decoding; seen here it is a reference to a master cell
                guard let row = u32(), let col = u16() else { return "(formula not decoded: token 0x01 truncated)" }
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
            case 0x18:   // PtgElf* / PtgList (natural-language and table references)
                let sub = u8().map { String(format: "0x%02X", $0) } ?? "?"
                return "(formula not decoded: token 0x18 \(sub))"
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
                if id == 255 {   // user-defined / add-in function: the name is the first argument
                    guard stack.count >= Int(count), count >= 1 else { return "(formula not decoded: user function without its name)" }
                    let arguments = Array(stack.suffix(Int(count) - 1)); stack.removeLast(Int(count) - 1)
                    let functionName = stack.removeLast()
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
            case 0x26, 0x27, 0x28:   // PtgMemArea / PtgMemErr / PtgMemNoMem: 4 unused bytes + cce
                guard skip(6) else { return "(formula not decoded: token 0x\(String(ptg, radix: 16, uppercase: true)) truncated)" }
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

/// The Excel function table (MS-XLS §2.5.198.17 Ftab): id → name and, for
/// PtgFunc, the fixed argument count.
enum XLSBFunctionTable {
    struct Entry { let name: String; let fixedArguments: Int? }

    static func entry(_ id: Int) -> Entry? {
        guard let (name, count) = table[id] else { return nil }
        return Entry(name: name, fixedArguments: count < 0 ? nil : count)
    }

    /// -1 = variable argument count (PtgFuncVar only).
    private static let table: [Int: (String, Int)] = [
        0: ("COUNT", -1), 1: ("IF", -1), 2: ("ISNA", 1), 3: ("ISERROR", 1), 4: ("SUM", -1), 5: ("AVERAGE", -1), 6: ("MIN", -1), 7: ("MAX", -1),
        8: ("ROW", -1), 9: ("COLUMN", -1), 10: ("NA", 0), 11: ("NPV", -1), 12: ("STDEV", -1), 13: ("DOLLAR", -1), 14: ("FIXED", -1),
        15: ("SIN", 1), 16: ("COS", 1), 17: ("TAN", 1), 18: ("ATAN", 1), 19: ("PI", 0), 20: ("SQRT", 1), 21: ("EXP", 1), 22: ("LN", 1),
        23: ("LOG10", 1), 24: ("ABS", 1), 25: ("INT", 1), 26: ("SIGN", 1), 27: ("ROUND", 2), 28: ("LOOKUP", -1), 29: ("INDEX", -1),
        30: ("REPT", 2), 31: ("MID", 3), 32: ("LEN", 1), 33: ("VALUE", 1), 34: ("TRUE", 0), 35: ("FALSE", 0), 36: ("AND", -1), 37: ("OR", -1),
        38: ("NOT", 1), 39: ("MOD", 2), 40: ("DCOUNT", 3), 41: ("DSUM", 3), 42: ("DAVERAGE", 3), 43: ("DMIN", 3), 44: ("DMAX", 3),
        45: ("DSTDEV", 3), 46: ("VAR", -1), 47: ("DVAR", 3), 48: ("TEXT", 2), 49: ("LINEST", -1), 50: ("TREND", -1), 51: ("LOGEST", -1),
        52: ("GROWTH", -1), 56: ("PV", -1), 57: ("FV", -1), 58: ("NPER", -1), 59: ("PMT", -1), 60: ("RATE", -1), 61: ("MIRR", 3), 62: ("IRR", -1),
        63: ("RAND", 0), 64: ("MATCH", -1), 65: ("DATE", 3), 66: ("TIME", 3), 67: ("DAY", 1), 68: ("MONTH", 1), 69: ("YEAR", 1), 70: ("WEEKDAY", -1),
        71: ("HOUR", 1), 72: ("MINUTE", 1), 73: ("SECOND", 1), 74: ("NOW", 0), 75: ("AREAS", 1), 76: ("ROWS", 1), 77: ("COLUMNS", 1),
        78: ("OFFSET", -1), 82: ("SEARCH", -1), 83: ("TRANSPOSE", 1), 86: ("TYPE", 1), 97: ("ATAN2", 2), 98: ("ASIN", 1), 99: ("ACOS", 1),
        100: ("CHOOSE", -1), 101: ("HLOOKUP", -1), 102: ("VLOOKUP", -1), 105: ("ISREF", 1), 109: ("LOG", -1), 111: ("CHAR", 1), 112: ("LOWER", 1),
        113: ("UPPER", 1), 114: ("PROPER", 1), 115: ("LEFT", -1), 116: ("RIGHT", -1), 117: ("EXACT", 2), 118: ("TRIM", 1), 119: ("REPLACE", 4),
        120: ("SUBSTITUTE", -1), 121: ("CODE", 1), 124: ("FIND", -1), 125: ("CELL", -1), 126: ("ISERR", 1), 127: ("ISTEXT", 1), 128: ("ISNUMBER", 1),
        129: ("ISBLANK", 1), 130: ("T", 1), 131: ("N", 1), 140: ("DATEVALUE", 1), 141: ("TIMEVALUE", 1), 142: ("SLN", 3), 143: ("SYD", 4), 144: ("DDB", -1),
        148: ("INDIRECT", -1), 162: ("CLEAN", 1), 163: ("MDETERM", 1), 164: ("MINVERSE", 1), 165: ("MMULT", 2), 167: ("IPMT", -1), 168: ("PPMT", -1),
        169: ("COUNTA", -1), 183: ("PRODUCT", -1), 184: ("FACT", 1), 189: ("DPRODUCT", 3), 190: ("ISNONTEXT", 1), 193: ("STDEVP", -1), 194: ("VARP", -1),
        195: ("DSTDEVP", 3), 196: ("DVARP", 3), 197: ("TRUNC", -1), 198: ("ISLOGICAL", 1), 199: ("DCOUNTA", 3), 204: ("USDOLLAR", -1), 205: ("FINDB", -1),
        206: ("SEARCHB", -1), 207: ("REPLACEB", 4), 208: ("LEFTB", -1), 209: ("RIGHTB", -1), 210: ("MIDB", 3), 211: ("LENB", 1), 212: ("ROUNDUP", 2),
        213: ("ROUNDDOWN", 2), 214: ("ASC", 1), 215: ("DBCS", 1), 216: ("RANK", -1), 219: ("ADDRESS", -1), 220: ("DAYS360", -1), 221: ("TODAY", 0),
        222: ("VDB", -1), 227: ("MEDIAN", -1), 228: ("SUMPRODUCT", -1), 229: ("SINH", 1), 230: ("COSH", 1), 231: ("TANH", 1), 232: ("ASINH", 1),
        233: ("ACOSH", 1), 234: ("ATANH", 1), 235: ("DGET", 3), 244: ("INFO", 1), 247: ("DB", -1), 252: ("FREQUENCY", 2), 261: ("ERROR.TYPE", 1),
        269: ("AVEDEV", -1), 270: ("BETADIST", -1), 271: ("GAMMALN", 1), 272: ("BETAINV", -1), 273: ("BINOMDIST", 4), 274: ("CHIDIST", 2), 275: ("CHIINV", 2),
        276: ("COMBIN", 2), 277: ("CONFIDENCE", 3), 278: ("CRITBINOM", 3), 279: ("EVEN", 1), 280: ("EXPONDIST", 3), 281: ("FDIST", 3), 282: ("FINV", 3),
        283: ("FISHER", 1), 284: ("FISHERINV", 1), 285: ("FLOOR", 2), 286: ("GAMMADIST", 4), 287: ("GAMMAINV", 3), 288: ("CEILING", 2), 289: ("HYPGEOMDIST", 4),
        290: ("LOGNORMDIST", 3), 291: ("LOGINV", 3), 292: ("NEGBINOMDIST", 3), 293: ("NORMDIST", 4), 294: ("NORMSDIST", 1), 295: ("NORMINV", 3),
        296: ("NORMSINV", 1), 297: ("STANDARDIZE", 3), 298: ("ODD", 1), 299: ("PERMUT", 2), 300: ("POISSON", 3), 301: ("TDIST", 3), 302: ("WEIBULL", 4),
        303: ("SUMXMY2", 2), 304: ("SUMX2MY2", 2), 305: ("SUMX2PY2", 2), 306: ("CHITEST", 2), 307: ("CORREL", 2), 308: ("COVAR", 2), 309: ("FORECAST", 3),
        310: ("FTEST", 2), 311: ("INTERCEPT", 2), 312: ("PEARSON", 2), 313: ("RSQ", 2), 314: ("STEYX", 2), 315: ("SLOPE", 2), 316: ("TTEST", 4), 317: ("PROB", -1),
        318: ("DEVSQ", -1), 319: ("GEOMEAN", -1), 320: ("HARMEAN", -1), 321: ("SUMSQ", -1), 322: ("KURT", -1), 323: ("SKEW", -1), 324: ("ZTEST", -1),
        325: ("LARGE", 2), 326: ("SMALL", 2), 327: ("QUARTILE", 2), 328: ("PERCENTILE", 2), 329: ("PERCENTRANK", -1), 330: ("MODE", -1), 331: ("TRIMMEAN", 2),
        332: ("TINV", 2), 336: ("CONCATENATE", -1), 337: ("POWER", 2), 342: ("RADIANS", 1), 343: ("DEGREES", 1), 344: ("SUBTOTAL", -1), 345: ("SUMIF", -1),
        346: ("COUNTIF", 2), 347: ("COUNTBLANK", 1), 350: ("ISPMT", 4), 351: ("DATEDIF", 3), 352: ("DATESTRING", 1), 353: ("NUMBERSTRING", 2), 354: ("ROMAN", -1),
        358: ("GETPIVOTDATA", -1), 359: ("HYPERLINK", -1), 360: ("PHONETIC", 1), 361: ("AVERAGEA", -1), 362: ("MAXA", -1), 363: ("MINA", -1), 364: ("STDEVPA", -1),
        365: ("VARPA", -1), 366: ("STDEVA", -1), 367: ("VARA", -1), 368: ("BAHTTEXT", 1), 369: ("THAIDAYOFWEEK", 1), 370: ("THAIDIGIT", 1), 371: ("THAIMONTHOFYEAR", 1),
        372: ("THAINUMSOUND", 1), 373: ("THAINUMSTRING", 1), 374: ("THAISTRINGLENGTH", 1), 375: ("ISTHAIDIGIT", 1), 376: ("ROUNDBAHTDOWN", 1), 377: ("ROUNDBAHTUP", 1),
        378: ("THAIYEAR", 1), 379: ("RTD", -1), 380: ("CUBEVALUE", -1), 381: ("CUBEMEMBER", -1), 382: ("CUBEMEMBERPROPERTY", 3), 383: ("CUBERANKEDMEMBER", -1),
        384: ("HEX2BIN", -1), 385: ("HEX2DEC", 1), 386: ("HEX2OCT", -1), 387: ("DEC2BIN", -1), 388: ("DEC2HEX", -1), 389: ("DEC2OCT", -1), 390: ("OCT2BIN", -1),
        391: ("OCT2HEX", -1), 392: ("OCT2DEC", 1), 393: ("BIN2DEC", 1), 394: ("BIN2OCT", -1), 395: ("BIN2HEX", -1), 396: ("IMSUB", 2), 397: ("IMDIV", 2),
        398: ("IMPOWER", 2), 399: ("IMABS", 1), 400: ("IMSQRT", 1), 401: ("IMLN", 1), 402: ("IMLOG2", 1), 403: ("IMLOG10", 1), 404: ("IMSIN", 1), 405: ("IMCOS", 1),
        406: ("IMEXP", 1), 407: ("IMARGUMENT", 1), 408: ("IMCONJUGATE", 1), 409: ("IMAGINARY", 1), 410: ("IMREAL", 1), 411: ("COMPLEX", -1), 412: ("IMSUM", -1),
        413: ("IMPRODUCT", -1), 414: ("SERIESSUM", 4), 415: ("FACTDOUBLE", 1), 416: ("SQRTPI", 1), 417: ("QUOTIENT", 2), 418: ("DELTA", -1), 419: ("GESTEP", -1),
        420: ("ISEVEN", 1), 421: ("ISODD", 1), 422: ("MROUND", 2), 423: ("ERF", -1), 424: ("ERFC", 1), 425: ("BESSELJ", 2), 426: ("BESSELK", 2), 427: ("BESSELY", 2),
        428: ("BESSELI", 2), 429: ("XIRR", -1), 430: ("XNPV", 3), 431: ("PRICEMAT", -1), 432: ("YIELDMAT", -1), 433: ("INTRATE", -1), 434: ("RECEIVED", -1),
        435: ("DISC", -1), 436: ("PRICEDISC", -1), 437: ("YIELDDISC", -1), 438: ("TBILLEQ", 3), 439: ("TBILLPRICE", 3), 440: ("TBILLYIELD", 3), 441: ("PRICE", -1),
        442: ("YIELD", -1), 443: ("DOLLARDE", 2), 444: ("DOLLARFR", 2), 445: ("NOMINAL", 2), 446: ("EFFECT", 2), 447: ("CUMPRINC", 6), 448: ("CUMIPMT", 6),
        449: ("EDATE", 2), 450: ("EOMONTH", 2), 451: ("YEARFRAC", -1), 452: ("COUPDAYBS", -1), 453: ("COUPDAYS", -1), 454: ("COUPDAYSNC", -1), 455: ("COUPNCD", -1),
        456: ("COUPNUM", -1), 457: ("COUPPCD", -1), 458: ("DURATION", -1), 459: ("MDURATION", -1), 460: ("ODDLPRICE", -1), 461: ("ODDLYIELD", -1),
        462: ("ODDFPRICE", -1), 463: ("ODDFYIELD", -1), 464: ("RANDBETWEEN", 2), 465: ("WEEKNUM", -1), 466: ("AMORDEGRC", -1), 467: ("AMORLINC", -1),
        468: ("CONVERT", 3), 469: ("ACCRINT", -1), 470: ("ACCRINTM", -1), 471: ("WORKDAY", -1), 472: ("NETWORKDAYS", -1), 473: ("GCD", -1), 474: ("MULTINOMIAL", -1),
        475: ("LCM", -1), 476: ("FVSCHEDULE", 2), 477: ("CUBEKPIMEMBER", -1), 478: ("CUBESET", -1), 479: ("CUBESETCOUNT", 1), 480: ("IFERROR", 2),
        481: ("COUNTIFS", -1), 482: ("SUMIFS", -1), 483: ("AVERAGEIF", -1), 484: ("AVERAGEIFS", -1),
    ]
}
