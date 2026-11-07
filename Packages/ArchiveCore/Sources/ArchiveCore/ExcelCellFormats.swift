//
//  ExcelCellFormats.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Excel/XLSB": a cell's displayed value is not its
//  raw value. Shared by the XLSX reader (styles.xml) and the XLSB reader
//  (styles.bin):
//
//    ExcelNumberFormat   which number formats are dates, times, percentages
//                        or currencies (built-in ids 14–22 / 45–47, custom
//                        codes with d/m/y/h/s outside quotes), and the ISO
//                        rendering of a date serial in the 1900 or 1904 system
//    ExcelFormulaText    a shared formula's master text re-based on another
//                        cell: relative A1 references shifted, absolute ones
//                        kept, anything that cannot be shifted named
//
//  Nothing here evaluates a formula; the stored serial stays in the output
//  next to the rendered date ("2025-01-15 (serial 45672)").
//

import Foundation

enum ExcelNumberFormat {

    enum Kind: String, Sendable, Equatable {
        case general, date, time, dateTime, elapsedTime, percent, currency, other
    }

    struct Format: Sendable, Equatable {
        let kind: Kind
        let code: String
    }

    /// Built-in number formats (ECMA-376 §18.8.30) — the ones that decide a kind.
    static func builtinCode(_ id: Int) -> String? {
        switch id {
        case 0: return "General"
        case 1: return "0"
        case 2: return "0.00"
        case 3: return "#,##0"
        case 4: return "#,##0.00"
        case 5: return "\"$\"#,##0_);(\"$\"#,##0)"
        case 6: return "\"$\"#,##0_);[Red](\"$\"#,##0)"
        case 7: return "\"$\"#,##0.00_);(\"$\"#,##0.00)"
        case 8: return "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)"
        case 9: return "0%"
        case 10: return "0.00%"
        case 11: return "0.00E+00"
        case 12: return "# ?/?"
        case 13: return "# ??/??"
        case 14: return "mm-dd-yy"
        case 15: return "d-mmm-yy"
        case 16: return "d-mmm"
        case 17: return "mmm-yy"
        case 18: return "h:mm AM/PM"
        case 19: return "h:mm:ss AM/PM"
        case 20: return "h:mm"
        case 21: return "h:mm:ss"
        case 22: return "m/d/yy h:mm"
        case 37: return "#,##0 ;(#,##0)"
        case 38: return "#,##0 ;[Red](#,##0)"
        case 39: return "#,##0.00;(#,##0.00)"
        case 40: return "#,##0.00;[Red](#,##0.00)"
        case 41: return "_(* #,##0_);_(* \\(#,##0\\);_(* \"-\"_);_(@_)"
        case 42: return "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)"
        case 43: return "_(* #,##0.00_);_(* \\(#,##0.00\\);_(* \"-\"??_);_(@_)"
        case 44: return "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)"
        case 45: return "mm:ss"
        case 46: return "[h]:mm:ss"
        case 47: return "mmss.0"
        case 48: return "##0.0E+0"
        case 49: return "@"
        default: return nil
        }
    }

    /// The kind of a number format: by its built-in id when it has one, by
    /// the letters of a custom code otherwise (d/y → date, h/s → time, m → a
    /// month unless hours or seconds are around, all outside quoted text and
    /// `[…]` sections; `[h]`/`[m]`/`[s]` are elapsed time; `%` a percentage;
    /// a currency sign — plain or `[$…]` — a currency).
    static func classify(id: Int, code: String?) -> Format {
        let text = code ?? builtinCode(id) ?? ""
        if code == nil {
            switch id {
            case 0: return Format(kind: .general, code: "General")
            case 14...17: return Format(kind: .date, code: text)
            case 18...21, 45, 47: return Format(kind: .time, code: text)
            case 46: return Format(kind: .elapsedTime, code: text)
            case 22: return Format(kind: .dateTime, code: text)
            case 5...8, 42, 44: return Format(kind: .currency, code: text)
            case 9, 10: return Format(kind: .percent, code: text)
            default: return Format(kind: text.isEmpty ? .general : .other, code: text)
            }
        }
        if text.isEmpty || text == "General" { return Format(kind: .general, code: text) }
        var hasDay = false, hasYear = false, hasHour = false, hasSecond = false, hasM = false
        var hasPercent = false, hasCurrency = false, elapsed = false
        var inQuote = false, escaped = false
        var bracket: String? = nil
        for ch in text {
            if escaped { escaped = false; continue }
            if inQuote {
                if ch == "\"" { inQuote = false } else if currencySigns.contains(ch) { hasCurrency = true }
                continue
            }
            if var open = bracket {
                if ch == "]" {
                    let body = open.lowercased()
                    if body.hasPrefix("$") { hasCurrency = true }
                    else if !body.isEmpty, body.allSatisfy({ "hms".contains($0) }) { elapsed = true }
                    bracket = nil
                } else { open.append(ch); bracket = open }
                continue
            }
            switch ch {
            case "\\", "_", "*": escaped = true          // the next character is literal / padding
            case "\"": inQuote = true
            case "[": bracket = ""
            case "d", "D": hasDay = true
            case "y", "Y": hasYear = true
            case "h", "H": hasHour = true
            case "s", "S": hasSecond = true
            case "m", "M": hasM = true
            case "%": hasPercent = true
            default: if currencySigns.contains(ch) { hasCurrency = true }
            }
        }
        if elapsed { return Format(kind: .elapsedTime, code: text) }
        let month = hasM && !(hasHour || hasSecond) || (hasM && (hasDay || hasYear))
        let isDate = hasDay || hasYear || month
        let isTime = hasHour || hasSecond || (hasM && !isDate)
        if isDate && isTime { return Format(kind: .dateTime, code: text) }
        if isDate { return Format(kind: .date, code: text) }
        if isTime { return Format(kind: .time, code: text) }
        if hasPercent { return Format(kind: .percent, code: text) }
        if hasCurrency { return Format(kind: .currency, code: text) }
        return Format(kind: .other, code: text)
    }

    private static let currencySigns: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₪", "฿"]

    /// The calendar value a date/time format shows for `serial`, ISO-shaped:
    /// "2025-01-15", "2025-01-15 14:30:00", "14:30:00" or "36:00:00" for an
    /// elapsed format. Nil when the kind is not a date or time, or the serial
    /// has no calendar day (negative, non-finite, day 0 of the 1900 system
    /// for a date format).
    static func render(serial: Double, kind: Kind, date1904: Bool) -> String? {
        guard serial.isFinite else { return nil }
        switch kind {
        case .date, .time, .dateTime, .elapsedTime: break
        default: return nil
        }
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - serial.rounded(.down)) * 86_400).rounded())
        if seconds >= 86_400 { seconds -= 86_400; days += 1 }
        let clock = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        switch kind {
        case .time:
            return clock
        case .elapsedTime:
            guard days >= 0 else { return nil }
            return String(format: "%02d:%02d:%02d", days * 24 + seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        default:
            guard let day = calendarDay(serialDays: days, date1904: date1904) else { return nil }
            return kind == .dateTime ? day + " " + clock : day
        }
    }

    /// "YYYY-MM-DD" of a whole-day serial. The 1900 system counts from
    /// 1899-12-31 as day 1 and keeps Lotus 1-2-3's 29 February 1900 as day 60
    /// (named as such, not silently moved); the 1904 system counts from
    /// 1904-01-01 as day 0.
    static func calendarDay(serialDays days: Int, date1904: Bool) -> String? {
        let epochDays: Int   // days since 1970-01-01
        if date1904 {
            guard days >= 0 else { return nil }
            epochDays = days - 24_107
        } else {
            guard days >= 1 else { return nil }
            if days == 60 { return "1900-02-29 (a day the 1900 system counts but the calendar does not have)" }
            epochDays = days < 60 ? days - 25_568 : days - 25_569
        }
        let (y, m, d) = civil(fromEpochDays: epochDays)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Proleptic Gregorian date of a day count since 1970-01-01 (Hinnant's algorithm).
    static func civil(fromEpochDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

enum ExcelFormulaText {

    /// "C7" → (column 2, row 6), zero-based; nil for anything else.
    static func parseA1(_ reference: String) -> (column: Int, row: Int)? {
        let letters = reference.prefix { $0.isLetter }
        let digits = reference.dropFirst(letters.count)
        guard !letters.isEmpty, letters.count <= 3, !digits.isEmpty, digits.allSatisfy({ $0.isNumber }),
              let row = Int(digits), row >= 1, let column = columnIndex(String(letters)) else { return nil }
        return (column, row - 1)
    }

    /// "A" → 0, "AA" → 26; nil when a letter is not A–Z.
    static func columnIndex(_ letters: String) -> Int? {
        var value = 0
        for ch in letters.uppercased() {
            guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { return nil }
            value = value * 26 + Int(ascii - 64)
        }
        return value - 1
    }

    static let maxRow = 1_048_576
    static let maxColumn = 16_384

    enum ShiftError: Error, Equatable {
        case outOfRange(String)
    }

    /// `formula` as written for its master cell, re-based by `rowDelta` rows
    /// and `columnDelta` columns: relative row/column parts of A1 references
    /// move, `$`-anchored parts stay, quoted strings and sheet names are not
    /// touched. Whole-column (`A:A`) and whole-row (`1:1`) ranges shift too.
    /// Throws when a shifted reference leaves the sheet.
    static func shift(_ formula: String, rowDelta: Int, columnDelta: Int) throws -> String {
        if rowDelta == 0 && columnDelta == 0 { return formula }
        let chars = Array(formula)
        var out = ""
        var i = 0
        func isTokenChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "$" || c == "_" || c == "." }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {                                   // string literal, copied whole
                var j = i + 1
                while j < chars.count { if chars[j] == "\"" { if j + 1 < chars.count, chars[j + 1] == "\"" { j += 2; continue }; break }; j += 1 }
                out += String(chars[i..<min(j + 1, chars.count)]); i = j + 1; continue
            }
            if c == "'" {                                    // quoted sheet name
                var j = i + 1
                while j < chars.count { if chars[j] == "'" { if j + 1 < chars.count, chars[j + 1] == "'" { j += 2; continue }; break }; j += 1 }
                out += String(chars[i..<min(j + 1, chars.count)]); i = j + 1; continue
            }
            guard isTokenChar(c) else { out.append(c); i += 1; continue }
            var j = i
            while j < chars.count, isTokenChar(chars[j]) { j += 1 }
            let token = String(chars[i..<j])
            let next: Character? = j < chars.count ? chars[j] : nil
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            let tokenAfter: String? = {
                guard next == ":" else { return nil }
                var k = j + 1; var t = ""
                while k < chars.count, isTokenChar(chars[k]) { t.append(chars[k]); k += 1 }
                return t
            }()
            if next == "(" || next == "!" || next == "[" {   // function, sheet name, structured reference
                out += token
            } else if let shifted = try shiftCell(token, rowDelta: rowDelta, columnDelta: columnDelta) {
                out += shifted
            } else if let columns = try shiftColumnOnly(token, neighbour: previous == ":" || tokenAfter.map(isColumnOnly) == true, columnDelta: columnDelta) {
                out += columns
            } else if let rows = try shiftRowOnly(token, neighbour: previous == ":" || tokenAfter.map(isRowOnly) == true, rowDelta: rowDelta) {
                out += rows
            } else {
                out += token
            }
            i = j
        }
        return out
    }

    private static func isColumnOnly(_ token: String) -> Bool {
        let body = token.hasPrefix("$") ? String(token.dropFirst()) : token
        return !body.isEmpty && body.count <= 3 && body.allSatisfy { $0.isLetter }
    }

    private static func isRowOnly(_ token: String) -> Bool {
        let body = token.hasPrefix("$") ? String(token.dropFirst()) : token
        return !body.isEmpty && body.allSatisfy { $0.isNumber }
    }

    /// "$B6" with rowDelta 1 → "$B7"; nil when the token is not a cell reference.
    private static func shiftCell(_ token: String, rowDelta: Int, columnDelta: Int) throws -> String? {
        var rest = Substring(token)
        let columnAbsolute = rest.hasPrefix("$"); if columnAbsolute { rest = rest.dropFirst() }
        let letters = rest.prefix { $0.isLetter }
        guard !letters.isEmpty, letters.count <= 3 else { return nil }
        rest = rest.dropFirst(letters.count)
        let rowAbsolute = rest.hasPrefix("$"); if rowAbsolute { rest = rest.dropFirst() }
        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber }), let row = Int(rest), let column = columnIndex(String(letters)) else { return nil }
        let newColumn = columnAbsolute ? column : column + columnDelta
        let newRow = rowAbsolute ? row : row + rowDelta
        guard newColumn >= 0, newColumn < maxColumn, newRow >= 1, newRow <= maxRow else { throw ShiftError.outOfRange(token) }
        return (columnAbsolute ? "$" : "") + OfficeTextExtractor.columnName(newColumn) + (rowAbsolute ? "$" : "") + String(newRow)
    }

    private static func shiftColumnOnly(_ token: String, neighbour: Bool, columnDelta: Int) throws -> String? {
        guard neighbour, isColumnOnly(token) else { return nil }
        let absolute = token.hasPrefix("$")
        guard let column = columnIndex(absolute ? String(token.dropFirst()) : token) else { return nil }
        if absolute { return token }
        let moved = column + columnDelta
        guard moved >= 0, moved < maxColumn else { throw ShiftError.outOfRange(token) }
        return OfficeTextExtractor.columnName(moved)
    }

    private static func shiftRowOnly(_ token: String, neighbour: Bool, rowDelta: Int) throws -> String? {
        guard neighbour, isRowOnly(token) else { return nil }
        let absolute = token.hasPrefix("$")
        guard let row = Int(absolute ? String(token.dropFirst()) : token) else { return nil }
        if absolute { return token }
        let moved = row + rowDelta
        guard moved >= 1, moved <= maxRow else { throw ShiftError.outOfRange(token) }
        return String(moved)
    }
}
