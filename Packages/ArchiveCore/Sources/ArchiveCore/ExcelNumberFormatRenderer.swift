//
//  ExcelNumberFormatRenderer.swift
//  ArchiveCore
//
//  A cell's displayed text, digit for digit, from its number format code
//  (ECMA-376 Part 1 §18.8.31 numFmts, and Excel's "Number format codes"
//  behaviour). Shared by the XLSX and XLSB readers through
//  `OfficeTextExtractor.cellText`.
//
//  What is rendered:
//    sections      up to four, `positive;negative;zero;text`; conditions
//                  (`[>=100]`, `[<0]`) choose the section the way Excel does,
//                  a value no condition takes falls back to General; colours
//                  (`[Red]`, `[Color10]`) and other bracket switches are ignored
//    literals      quoted text, backslash escapes, `_x` (one space), `*x`
//                  (repeat-to-fill, dropped: there is no column width here),
//                  `$ - + ( ) : / space` and any other plain character
//    numbers       `0 # ?`, the decimal point, thousands separators, trailing
//                  commas scaling by 1,000, `%` (×100 each), `E+00` / `E-00`
//                  (engineering form when the mantissa has `#` placeholders),
//                  fractions (`# ?/?`, `# ??/??`, fixed denominators `?/16`),
//                  `General` inside a section, `@` in the text section
//    currencies    `[$€-407]` keeps the symbol and drops the locale; `[$-409]`
//                  is dropped; `[$-F800]` / `[$-F400]` (system long date /
//                  system time) render as en-US `dddd, mmmm d, yyyy` / `h:mm:ss AM/PM`
//    dates/times   y yy yyy yyyy, m mm mmm mmmm mmmmm, d dd ddd dddd, h hh,
//                  m / mm as minutes next to an hour or second, s ss, `.0`–`.000`
//                  fractions of a second, AM/PM and A/P, elapsed `[h] [mm] [ss]`;
//                  the 1900 date system with Lotus 1-2-3's 29 February 1900
//                  (serial 60) and day 0 shown as 1/0/1900, and the 1904 system
//    rounding      half away from zero at the displayed precision, on the
//                  value's 15 significant digits (Excel's own precision), so
//                  0.035 shown with two decimals is 0.04, not 0.03
//
//  Rendered in en-US, invariant: the codes in the file are the invariant
//  ones (`.` is always the decimal point, `,` the thousands separator), month
//  and day names are English, and the built-in formats whose look depends on
//  the reader's locale (14, 22 and the East Asian 27–36 / 50–58) are taken
//  as Excel en-US shows them. A German Excel shows the same cell as
//  "15.01.2025"; this renderer writes "1/15/2025".
//
//  Not rendered: `[DBNum1]`-style native digits, Buddhist / Japanese era
//  years (`b`, `e`, `g`), and column-width effects (`*` fill, `####` for
//  a value wider than its column). A value Excel cannot show in the
//  chosen format (a negative or post-9999 date) returns nil and the caller
//  keeps the stored value.
//

import Foundation

enum ExcelNumberFormatRenderer {

    // MARK: - Entry points

    /// The text Excel displays for `value` in the format `code`; nil when
    /// Excel would show `#####` (a negative date, a date past 9999-12-31).
    static func render(_ value: Double, code: String, date1904: Bool) -> String? {
        guard value.isFinite else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("General") == .orderedSame { return general(value) }
        let sections = parse(systemFormats(code))
        // A last section holding `@` (or a fourth section) is for text; the rest are for numbers.
        var numeric = Array(sections.prefix(3))
        if sections.count < 4, let last = numeric.last, last.hasText { numeric.removeLast() }
        guard !numeric.isEmpty else { return general(value) }
        let pos = numeric[0]
        switch numeric.count {
        case 1:
            if let condition = pos.condition, !condition.holds(value) { return general(value) }
            return renderSection(pos, value, date1904: date1904)
        case 2:
            let neg = numeric[1]
            if value < 0 && pos.condition == nil && neg.condition == nil { return renderSection(neg, -value, date1904: date1904) }
            if (pos.condition == nil && value >= 0) || (pos.condition?.holds(value) ?? false) { return renderSection(pos, value, date1904: date1904) }
            if neg.condition == nil || neg.condition!.holds(value) { return renderSection(neg, value, date1904: date1904) }
            return String(repeating: "#", count: 11)   // Excel: no section takes the value
        default:
            let neg = numeric[1], zero = numeric[2]
            if value < 0 && neg.condition == nil && pos.condition.map({ !$0.holds(value) }) ?? true {
                return renderSection(neg, -value, date1904: date1904)
            }
            if (pos.condition == nil && value > 0) || (pos.condition?.holds(value) ?? false) { return renderSection(pos, value, date1904: date1904) }
            if (neg.condition == nil && value < 0) || (neg.condition?.holds(value) ?? false) { return renderSection(neg, value, date1904: date1904) }
            return renderSection(zero, value, date1904: date1904)
        }
    }

    /// The text a text cell shows: the format's text section (the fourth,
    /// or a last section holding `@`) with `@` replaced by `text`. Nil when
    /// the format has no text section — Excel then shows the text as typed.
    static func renderText(_ text: String, code: String) -> String? {
        let sections = parse(systemFormats(code))
        let section: Section?
        if sections.count >= 4 { section = sections[3] } else if let last = sections.last, last.hasText { section = last } else { section = nil }
        guard let section else { return nil }
        var out = ""
        for token in section.tokens {
            switch token {
            case .at: out += text
            case .literal(let s): out += s
            case .digit(let c): out.append(c)
            case .point: out += "."
            case .comma: out += ","
            case .percent: out += "%"
            case .slash: out += "/"
            default: break
            }
        }
        return out
    }

    /// Excel's General format: at most 11 characters (sign apart) — up to ten
    /// significant digits in decimal form between 1E-9 and 1E+11, scientific
    /// with up to six significant digits outside it ("1.12346E+11", "1E-10").
    static func general(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if value == 0 { return "0" }
        let sign = value < 0 ? "-" : ""
        let decimal = Decimal15(abs(value))
        let e10 = decimal.pointPosition - 1
        if e10 < 11 && e10 >= -9 {
            let integerDigits = max(decimal.pointPosition, 1)
            let (int, frac) = decimal.rounded(decimals: max(0, 10 - integerDigits))
            if int.count <= 11 {
                let fraction = String(frac.reversed().drop { $0 == "0" }.reversed())
                return sign + (int.isEmpty ? "0" : int) + (fraction.isEmpty ? "" : "." + fraction)
            }
        }
        var (mantissa, exponent) = decimal.scientific(decimals: 5)
        while mantissa.contains(".") && (mantissa.hasSuffix("0") || mantissa.hasSuffix(".")) { mantissa.removeLast() }
        let digits = String(format: "%02d", abs(exponent))
        return sign + mantissa + "E" + (exponent < 0 ? "-" : "+") + digits
    }

    // MARK: - Tokens and sections

    enum DateToken: Equatable {
        case year(Int), month(Int), day(Int), hour(Int), minute(Int), second(Int)
        case minuteOrMonth(Int)
        case subsecond(Int)
        case ampm(full: Bool, lowerA: Bool, lowerP: Bool)
        case elapsedHour(Int), elapsedMinute(Int), elapsedSecond(Int)
    }

    enum Token: Equatable {
        case literal(String)
        case digit(Character)          // 0 # ?
        case point
        case comma
        case percent
        case exponent(String, plus: Bool)   // "E" / "e", + or -
        case slash
        case at
        case general
        case date(DateToken)
    }

    struct Condition: Equatable {
        let op: String
        let operand: Double
        func holds(_ v: Double) -> Bool {
            switch op {
            case "<": return v < operand
            case "<=": return v <= operand
            case ">": return v > operand
            case ">=": return v >= operand
            case "=": return v == operand
            case "<>": return v != operand
            default: return false
            }
        }
    }

    struct Section {
        var tokens: [Token] = []
        var condition: Condition? = nil
        var hasText: Bool { tokens.contains(.at) }
        var isDate: Bool { tokens.contains { if case .date = $0 { return true } else { return false } } }
    }

    /// `[$-F800]` (system long date) and `[$-F400]` (system time) stand for
    /// the reader's own formats; en-US is used.
    private static func systemFormats(_ code: String) -> String {
        let upper = code.uppercased()
        if upper.contains("[$-F800]") || upper.contains("[$-X-SYSDATE]") { return "dddd, mmmm d, yyyy" }
        if upper.contains("[$-F400]") || upper.contains("[$-X-SYSTIME]") { return "h:mm:ss AM/PM" }
        return code
    }

    static func parse(_ code: String) -> [Section] {
        let chars = Array(code)
        var sections: [Section] = []
        var current = Section()
        var i = 0
        func lower(_ k: Int) -> Character? { k < chars.count ? Character(chars[k].lowercased()) : nil }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case ";":
                sections.append(current); current = Section(); i += 1
            case "\"":
                var j = i + 1; var text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                current.tokens.append(.literal(text)); i = j + 1
            case "\\":
                if i + 1 < chars.count { current.tokens.append(.literal(String(chars[i + 1]))) }
                i += 2
            case "_":
                current.tokens.append(.literal(" ")); i += 2
            case "*":
                i += 2                                  // fill character: needs a column width, dropped
            case "[":
                var j = i + 1; var body = ""
                while j < chars.count, chars[j] != "]" { body.append(chars[j]); j += 1 }
                i = j + 1
                bracket(body, into: &current)
            case "0", "#", "?":
                current.tokens.append(.digit(c)); i += 1
            case ".": current.tokens.append(.point); i += 1
            case ",": current.tokens.append(.comma); i += 1
            case "%": current.tokens.append(.percent); i += 1
            case "/": current.tokens.append(.slash); i += 1
            case "@": current.tokens.append(.at); i += 1
            case "E" where i + 1 < chars.count && (chars[i + 1] == "+" || chars[i + 1] == "-"),
                 "e" where i + 1 < chars.count && (chars[i + 1] == "+" || chars[i + 1] == "-"):
                current.tokens.append(.exponent(String(c), plus: chars[i + 1] == "+")); i += 2
            default:
                let l = Character(c.lowercased())
                if l == "g", String(chars[i..<min(i + 7, chars.count)]).lowercased() == "general" {
                    current.tokens.append(.general); i += 7; continue
                }
                if l == "a" {
                    if String(chars[i..<min(i + 5, chars.count)]).lowercased() == "am/pm" {
                        current.tokens.append(.date(.ampm(full: true, lowerA: false, lowerP: false))); i += 5; continue
                    }
                    if lower(i + 1) == "/", lower(i + 2) == "p" {
                        current.tokens.append(.date(.ampm(full: false, lowerA: c == "a", lowerP: chars[i + 2] == "p"))); i += 3; continue
                    }
                }
                if "ymdhs".contains(l) {
                    var n = 0
                    while i < chars.count, Character(chars[i].lowercased()) == l { n += 1; i += 1 }
                    switch l {
                    case "y": current.tokens.append(.date(.year(n)))
                    case "m": current.tokens.append(.date(n <= 2 ? .minuteOrMonth(n) : .month(n)))
                    case "d": current.tokens.append(.date(.day(n)))
                    case "h": current.tokens.append(.date(.hour(n)))
                    default: current.tokens.append(.date(.second(n)))
                    }
                    continue
                }
                current.tokens.append(.literal(String(c))); i += 1
            }
        }
        sections.append(current)
        return sections.map(resolveDates)
    }

    /// One `[…]` switch: a currency/locale, a condition, an elapsed-time unit,
    /// or a colour / other switch (ignored).
    private static func bracket(_ body: String, into section: inout Section) {
        if body.hasPrefix("$") {
            let symbol = body.dropFirst().prefix { $0 != "-" }
            if !symbol.isEmpty { section.tokens.append(.literal(String(symbol))) }
            return
        }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        for op in ["<=", ">=", "<>", "<", ">", "="] where trimmed.hasPrefix(op) {
            if let operand = Double(trimmed.dropFirst(op.count).trimmingCharacters(in: .whitespaces)) {
                section.condition = Condition(op: op, operand: operand)
            }
            return
        }
        let lower = body.lowercased()
        if let first = lower.first, "hms".contains(first), lower.allSatisfy({ $0 == first }) {
            switch first {
            case "h": section.tokens.append(.date(.elapsedHour(lower.count)))
            case "m": section.tokens.append(.date(.elapsedMinute(lower.count)))
            default: section.tokens.append(.date(.elapsedSecond(lower.count)))
            }
        }
    }

    /// In a date section: `m`/`mm` is minutes next to an hour or a second,
    /// a month otherwise; `.0`, `.00`, `.000` are fractions of a second.
    private static func resolveDates(_ section: Section) -> Section {
        guard section.isDate else { return section }
        var tokens: [Token] = []
        var i = 0
        let source = section.tokens
        while i < source.count {
            if source[i] == .point, i + 1 < source.count, source[i + 1] == .digit("0") {
                var n = 0
                while i + 1 + n < source.count, source[i + 1 + n] == .digit("0") { n += 1 }
                tokens.append(.date(.subsecond(n))); i += 1 + n; continue
            }
            tokens.append(source[i]); i += 1
        }
        func dateAt(_ k: Int) -> DateToken? { if case .date(let d) = tokens[k] { return d } else { return nil } }
        func isHour(_ d: DateToken?) -> Bool { if case .hour = d { return true }; if case .elapsedHour = d { return true }; return false }
        func isSecond(_ d: DateToken?) -> Bool { if case .second = d { return true }; if case .elapsedSecond = d { return true }; return false }
        for k in tokens.indices {
            guard case .date(.minuteOrMonth(let n)) = tokens[k] else { continue }
            var previous: DateToken? = nil, next: DateToken? = nil
            func counts(_ d: DateToken) -> Bool {
                switch d { case .ampm, .subsecond: return false; default: return true }
            }
            var p = k - 1
            while p >= 0 { if let d = dateAt(p), counts(d) { previous = d; break }; p -= 1 }
            var q = k + 1
            while q < tokens.count { if let d = dateAt(q), counts(d) { next = d; break }; q += 1 }
            tokens[k] = .date(isHour(previous) || isSecond(previous) || isSecond(next) ? .minute(n) : .month(n))
        }
        var out = section
        out.tokens = tokens
        return out
    }

    // MARK: - Rendering one section

    private static func renderSection(_ section: Section, _ value: Double, date1904: Bool) -> String? {
        if section.isDate { return renderDate(section, value, date1904: date1904) }
        let tokens = section.tokens
        let digits = tokens.filter { if case .digit = $0 { return true } else { return false } }.count
        if digits == 0 {
            // Literal-only section, or General with words around it.
            if tokens.contains(.general) {
                return (value < 0 ? "-" : "") + tokens.map { t -> String in
                    switch t {
                    case .general: return general(abs(value))
                    case .literal(let s): return s
                    case .percent: return "%"
                    case .comma: return ","
                    case .point: return "."
                    case .slash: return "/"
                    default: return ""
                    }
                }.joined()
            }
            return literalText(tokens)
        }
        if let e = tokens.firstIndex(where: { if case .exponent = $0 { return true } else { return false } }) {
            return renderScientific(tokens, exponentAt: e, value)
        }
        if let fraction = FractionLayout(tokens) {
            return fraction.render(value)
        }
        return renderDecimal(tokens, value)
    }

    private static func literalText(_ tokens: [Token]) -> String {
        tokens.map { t -> String in
            switch t {
            case .literal(let s): return s
            case .percent: return "%"
            case .comma: return ","
            case .point: return "."
            case .slash: return "/"
            default: return ""
            }
        }.joined()
    }

    /// Plain and decimal numbers: integer placeholders filled from the
    /// right (extra digits go to the leftmost one), grouping, scaling,
    /// percent, decimals with `#` / `?` trailing-zero handling.
    private static func renderDecimal(_ tokens: [Token], _ value: Double) -> String {
        let pointIndex = tokens.firstIndex(of: .point)
        let integerEnd = pointIndex ?? tokens.count
        var scaled = abs(value)
        let percents = tokens.filter { $0 == .percent }.count
        for _ in 0..<percents { scaled *= 100 }
        let commaRoles = commaRoles(tokens, integerEnd: integerEnd)
        for role in commaRoles.values where role == .scale { scaled /= 1000 }
        let fractionPlaceholders: [Character] = tokens[(pointIndex.map { $0 + 1 } ?? tokens.count)...].compactMap { if case .digit(let c) = $0 { return c } else { return nil } }
        let (int, frac) = Decimal15(scaled).rounded(decimals: fractionPlaceholders.count)
        let integer = fillInteger(tokens, range: 0..<integerEnd, digits: int, grouping: commaRoles.values.contains(.group), roles: commaRoles,
                                  digitsBeforePoint: pointIndex != nil)
        var out = (value < 0 ? "-" : "") + integer
        if let pointIndex {
            out += "."
            // Trailing zeros: `#` drops them, `?` turns them into spaces, `0` keeps them.
            var shown = Array(frac).map { String($0) }
            var k = fractionPlaceholders.count - 1
            while k >= 0, shown[k] == "0", fractionPlaceholders[k] != "0" {
                shown[k] = fractionPlaceholders[k] == "?" ? " " : ""
                k -= 1
            }
            var d = 0
            for t in tokens[(pointIndex + 1)...] {
                switch t {
                case .digit: out += shown[d]; d += 1
                case .literal(let s): out += s
                case .percent: out += "%"
                case .point: out += "."
                case .slash: out += "/"
                case .general: out += general(abs(value))
                default: break   // commas after the point scale or are dropped
                }
            }
        }
        return out
    }

    enum CommaRole { case group, scale, literal }

    /// A comma between integer placeholders groups thousands; one after the
    /// last placeholder of the integer part (or of the decimals) scales by
    /// 1,000; one before any placeholder is plain text.
    private static func commaRoles(_ tokens: [Token], integerEnd: Int) -> [Int: CommaRole] {
        var roles: [Int: CommaRole] = [:]
        func isDigit(_ t: Token) -> Bool { if case .digit = t { return true } else { return false } }
        for (k, t) in tokens.enumerated() where t == .comma {
            if k < integerEnd {
                let before = tokens[..<k].contains(where: isDigit)
                let after = tokens[(k + 1)..<integerEnd].contains(where: isDigit)
                roles[k] = before && after ? .group : before ? .scale : .literal
            } else {
                let after = tokens[(k + 1)...].contains(where: isDigit)
                roles[k] = after ? .literal : .scale
                if after { roles[k] = nil }   // a comma between decimals is dropped
            }
        }
        return roles
    }

    /// The integer part: placeholders in `range` filled right to left with
    /// `digits` (no leading zeros; empty for zero), literals kept in place.
    private static func fillInteger(_ tokens: [Token], range: Range<Int>, digits: String, grouping: Bool, roles: [Int: CommaRole],
                                    digitsBeforePoint: Bool) -> String {
        let reversedDigits = Array(digits.reversed())
        var used = 0
        var position = 0
        var pieces: [String] = []   // built right to left
        func slot(_ ch: String) {
            guard !ch.isEmpty else { return }
            position += 1
            if grouping, position > 1, (position - 1) % 3 == 0 { pieces.append(ch == " " ? " " : ",") }
            pieces.append(ch)
        }
        let placeholderIndices = range.filter { if case .digit = tokens[$0] { return true } else { return false } }
        for k in range.reversed() {
            switch tokens[k] {
            case .digit(let c):
                if used < reversedDigits.count { slot(String(reversedDigits[used])); used += 1 } else { slot(c == "0" ? "0" : c == "?" ? " " : "") }
                if k == placeholderIndices.first { while used < reversedDigits.count { slot(String(reversedDigits[used])); used += 1 } }
            case .literal(let s): pieces.append(s)
            case .comma: if roles[k] == .literal { pieces.append(",") }
            case .percent: pieces.append("%")
            case .slash: pieces.append("/")
            case .point: pieces.append(".")
            case .general: pieces.append(digits.isEmpty ? "0" : digits)
            default: break
            }
        }
        var out = pieces.reversed().joined()
        if placeholderIndices.isEmpty && digitsBeforePoint { out += digits }
        return out
    }

    /// `0.00E+00`, `##0.0E+0`: the mantissa keeps as many integer digits as
    /// it has placeholders, or — with `#` among them — the exponent is a
    /// multiple of the placeholder count (engineering notation).
    private static func renderScientific(_ tokens: [Token], exponentAt e: Int, _ value: Double) -> String {
        guard case .exponent(let letter, let plus) = tokens[e] else { return "" }
        let mantissaTokens = Array(tokens[..<e])
        let pointIndex = mantissaTokens.firstIndex(of: .point)
        let integerEnd = pointIndex ?? mantissaTokens.count
        let integerPlaceholders: [Character] = mantissaTokens[..<integerEnd].compactMap { if case .digit(let c) = $0 { return c } else { return nil } }
        let decimals = pointIndex.map { p in mantissaTokens[(p + 1)...].filter { if case .digit = $0 { return true } else { return false } }.count } ?? 0
        let nInt = max(integerPlaceholders.count, 1)
        let engineering = integerPlaceholders.count > 1 && integerPlaceholders.contains(where: { $0 != "0" })
        let magnitude = abs(value)
        var exponent = 0
        var int = "", frac = String(repeating: "0", count: decimals)
        if magnitude != 0 {
            let decimal = Decimal15(magnitude)
            let e10 = decimal.pointPosition - 1
            exponent = engineering ? Int((Double(e10) / Double(nInt)).rounded(.down)) * nInt : e10 - (nInt - 1)
            for _ in 0..<3 {
                (int, frac) = decimal.shifted(by: -exponent).rounded(decimals: decimals)
                let allowed = engineering ? nInt : nInt
                if int.count > allowed { exponent += engineering ? nInt : 1 } else { break }
            }
        }
        let roles = commaRoles(mantissaTokens, integerEnd: integerEnd)
        var out = (value < 0 ? "-" : "") + fillInteger(mantissaTokens, range: 0..<integerEnd, digits: int, grouping: roles.values.contains(.group),
                                                         roles: roles, digitsBeforePoint: pointIndex != nil)
        if let pointIndex {
            out += "."
            var d = 0
            let shown = Array(frac)
            for t in mantissaTokens[(pointIndex + 1)...] {
                switch t {
                case .digit: out.append(shown[d]); d += 1
                case .literal(let s): out += s
                case .percent: out += "%"
                default: break
                }
            }
        }
        out += letter + (exponent < 0 ? "-" : plus ? "+" : "")
        let exponentTokens = tokens[(e + 1)...]
        let zeros = exponentTokens.filter { $0 == .digit("0") }.count
        var exponentDigits = String(abs(exponent))
        if exponentDigits.count < zeros { exponentDigits = String(repeating: "0", count: zeros - exponentDigits.count) + exponentDigits }
        var wroteDigits = false
        for t in exponentTokens {
            switch t {
            case .digit: if !wroteDigits { out += exponentDigits; wroteDigits = true }
            case .literal(let s): out += s
            case .percent: out += "%"
            default: break
            }
        }
        if !wroteDigits { out += exponentDigits }
        return out
    }

    // MARK: - Fractions

    /// `# ?/?`, `# ??/??`, `?/16`, `# #/#`: the integer placeholders, the
    /// numerator run just before the bar, the denominator after it.
    struct FractionLayout {
        let tokens: [Token]
        let integer: [Int]        // token indices of integer placeholders
        let numerator: [Int]
        let denominator: [Int]    // placeholder or fixed-digit token indices
        let fixedDenominator: Int?
        let slash: Int

        init?(_ tokens: [Token]) {
            guard let slash = tokens.firstIndex(of: .slash) else { return nil }
            func isDigit(_ k: Int) -> Bool { if case .digit = tokens[k] { return true } else { return false } }
            func literalDigit(_ k: Int) -> Character? { if case .literal(let s) = tokens[k], s.count == 1, let c = s.first, c.isASCII, c.isNumber { return c } else { return nil } }
            // Denominator: after any plain literals, placeholders or a fixed number.
            var k = slash + 1
            while k < tokens.count, !isDigit(k), literalDigit(k) == nil { if case .literal = tokens[k] { k += 1 } else { break } }
            var denominator: [Int] = []
            var fixed = ""
            if k < tokens.count, let first = literalDigit(k), first != "0" {
                while k < tokens.count, let c = literalDigit(k) ?? (tokens[k] == .digit("0") ? "0" : nil) { fixed.append(c); denominator.append(k); k += 1 }
            } else {
                while k < tokens.count, isDigit(k) { denominator.append(k); k += 1 }
            }
            guard !denominator.isEmpty else { return nil }
            // Numerator: the placeholder run nearest the bar.
            var n = slash - 1
            while n >= 0, !isDigit(n) { if case .literal = tokens[n] { n -= 1 } else { return nil } }
            guard n >= 0 else { return nil }
            var numerator: [Int] = []
            while n >= 0, isDigit(n) { numerator.insert(n, at: 0); n -= 1 }
            let integer = (0..<max(n + 1, 0)).filter(isDigit)
            self.tokens = tokens; self.integer = integer; self.numerator = numerator; self.denominator = denominator
            self.fixedDenominator = fixed.isEmpty ? nil : Int(fixed); self.slash = slash
        }

        func placeholder(_ k: Int) -> Character { if case .digit(let c) = tokens[k] { return c } else { return "0" } }

        func render(_ value: Double) -> String {
            let magnitude = abs(value)
            let hasInteger = !integer.isEmpty
            var whole = hasInteger ? magnitude.rounded(.down) : 0
            let part = magnitude - whole
            var num: Double, den: Double
            if let fixed = fixedDenominator, fixed > 0 {
                den = Double(fixed); num = (part * den).rounded(.toNearestOrAwayFromZero)
            } else {
                let maxDen = Int(pow(10, Double(denominator.count))) - 1
                (num, den) = bestRational(part, maxDenominator: max(maxDen, 1))
            }
            if hasInteger && num == den && den > 0 { whole += 1; num = 0 }
            let numeratorHasZero = numerator.contains { placeholder($0) == "0" }
            // A `?` anywhere keeps the width of a whole number's missing fraction as spaces;
            // a `?` in the integer or the numerator turns the text between them into spaces.
            let anyQuestion = (integer + numerator + (fixedDenominator == nil ? denominator : [])).contains { placeholder($0) == "?" }
            let leadingQuestion = (integer + numerator).contains { placeholder($0) == "?" }
            let integerHasZero = integer.contains { placeholder($0) == "0" }
            let fractionStart = (integer.last.map { $0 + 1 }) ?? 0
            let fractionEnd = denominator.last!
            var out = value < 0 ? "-" : ""
            let wholeDigits = whole == 0 ? "" : String(format: "%.0f", whole)
            if hasInteger && num == 0 && !numeratorHasZero {
                // A whole number: the integer shows (at least "0"); the fraction part
                // becomes spaces when it has `?` placeholders, else disappears.
                out += fill(0..<fractionStart, digits: wholeDigits.isEmpty ? "0" : wholeDigits)
                if anyQuestion { out += String(repeating: " ", count: width(fractionStart...fractionEnd)) }
                out += plain((fractionEnd + 1)..<tokens.count)
                return out
            }
            if hasInteger && whole == 0 {
                let showZero = num == 0 && placeholder(integer.last!) != "#"   // "?:0/1" shows 0:0/1
                out += fill(0..<fractionStart, digits: showZero ? "0" : "")
                let keep = integerHasZero || showZero
                for k in fractionStart..<numerator.first! {
                    if case .literal(let s) = tokens[k] { out += keep ? s : leadingQuestion ? String(repeating: " ", count: s.count) : "" }
                }
            } else {
                out += fill(0..<numerator.first!, digits: wholeDigits)
            }
            out += fill(numerator.first!..<(numerator.last! + 1), digits: String(format: "%.0f", num))
            for k in (numerator.last! + 1)..<denominator.first! {
                switch tokens[k] {
                case .slash: out += "/"
                case .literal(let s): out += s
                default: break
                }
            }
            if fixedDenominator != nil {
                out += denominator.map { k -> String in if case .literal(let s) = tokens[k] { return s } else { return "0" } }.joined()
            } else {
                let digits = String(format: "%.0f", den)
                let pad = max(0, denominator.count - digits.count)
                let padding = denominator.prefix(pad).map { placeholder($0) }
                out += String(repeating: "0", count: padding.filter { $0 == "0" }.count) + digits + String(repeating: " ", count: padding.filter { $0 == "?" }.count)
            }
            out += plain((fractionEnd + 1)..<tokens.count)
            return out
        }

        private func width(_ range: ClosedRange<Int>) -> Int {
            range.reduce(0) { sum, k in
                if case .literal(let s) = tokens[k] { return sum + s.count }
                return sum + 1
            }
        }

        private func plain(_ range: Range<Int>) -> String {
            range.map { k -> String in
                switch tokens[k] {
                case .literal(let s): return s
                case .percent: return "%"
                case .slash: return "/"
                default: return ""
                }
            }.joined()
        }

        /// Placeholders in `range` filled right to left; leftover digits go to the leftmost.
        private func fill(_ range: Range<Int>, digits: String) -> String {
            let reversed = Array(digits.reversed())
            var used = 0
            var pieces: [String] = []
            let first = range.first { if case .digit = tokens[$0] { return true } else { return false } }
            for k in range.reversed() {
                switch tokens[k] {
                case .digit(let c):
                    if used < reversed.count { pieces.append(String(reversed[used])); used += 1 } else { pieces.append(c == "0" ? "0" : c == "?" ? " " : "") }
                    if k == first { while used < reversed.count { pieces.append(String(reversed[used])); used += 1 } }
                case .literal(let s): pieces.append(s)
                case .percent: pieces.append("%")
                default: break
                }
            }
            return pieces.reversed().joined()
        }
    }

    /// The closest fraction to `x` (0 ≤ x) with a denominator up to `maxDenominator`.
    static func bestRational(_ x: Double, maxDenominator: Int) -> (Double, Double) {
        if x == 0 { return (0, 1) }
        var p0 = 0.0, q0 = 1.0, p1 = 1.0, q1 = 0.0
        var n = x
        let limit = Double(maxDenominator)
        for _ in 0..<64 {
            let a = n.rounded(.down)
            let q2 = q0 + a * q1
            if q2 > limit { break }
            (p0, q0, p1, q1) = (p1, q1, p0 + a * p1, q2)
            let rest = n - a
            if rest < 1e-12 { break }
            n = 1 / rest
        }
        guard q1 > 0 else { return ((x * limit).rounded(), limit) }
        let k = ((limit - q0) / q1).rounded(.down)
        let bound1 = (p0 + k * p1, q0 + k * q1)
        let bound2 = (p1, q1)
        return abs(bound2.0 / bound2.1 - x) <= abs(bound1.0 / bound1.1 - x) ? bound2 : bound1
    }

    // MARK: - Dates and times

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static func renderDate(_ section: Section, _ value: Double, date1904: Bool) -> String? {
        let tokens = section.tokens
        var elapsedH = false, elapsedM = false, elapsedS = false, twelveHour = false, precision = 0
        for case .date(let d) in tokens {
            switch d {
            case .elapsedHour: elapsedH = true
            case .elapsedMinute: elapsedM = true
            case .elapsedSecond: elapsedS = true
            case .ampm: twelveHour = true
            case .subsecond(let n): precision = max(precision, min(n, 3))
            default: break
            }
        }
        let elapsed = elapsedH || elapsedM || elapsedS
        if value < 0 && !elapsed { return nil }       // Excel shows ##### for a negative date or time
        let scale = Int64(pow(10, Double(precision)))
        let unitsPerSecond = Double(scale)
        let totalUnitsDouble = (abs(value) * 86_400 * unitsPerSecond).rounded(.toNearestOrAwayFromZero)
        guard totalUnitsDouble < 9.0e15 else { return nil }
        let totalUnits = Int64(totalUnitsDouble)
        let unitsPerDay = 86_400 * scale
        let days = Int(totalUnits / unitsPerDay)
        let totalSeconds = totalUnits / scale
        let subsecondUnits = totalUnits % scale
        let secondOfDay = Int((totalUnits % unitsPerDay) / scale)
        var calendar: (y: Int, m: Int, d: Int, weekday: Int)? = nil
        func date() -> (y: Int, m: Int, d: Int, weekday: Int)? {
            if let calendar { return calendar }
            calendar = civilDay(days, date1904: date1904)
            return calendar
        }
        var out = value < 0 ? "-" : ""
        for token in tokens {
            switch token {
            case .literal(let s): out += s
            case .percent: out += "%"
            case .comma: out += ","
            case .point: out += "."
            case .slash: out += "/"
            case .digit(let c): out.append(c)
            case .date(let d):
                switch d {
                case .year(let n):
                    guard let day = date() else { return nil }
                    out += n <= 2 ? String(format: "%02d", day.y % 100) : String(day.y)
                case .month(let n), .minuteOrMonth(let n):
                    guard let day = date() else { return nil }
                    switch n {
                    case 1: out += String(day.m)
                    case 2: out += String(format: "%02d", day.m)
                    case 3: out += String(monthNames[day.m - 1].prefix(3))
                    case 5: out += String(monthNames[day.m - 1].prefix(1))
                    default: out += monthNames[day.m - 1]
                    }
                case .day(let n):
                    guard let day = date() else { return nil }
                    switch n {
                    case 1: out += String(day.d)
                    case 2: out += String(format: "%02d", day.d)
                    case 3: out += String(dayNames[day.weekday].prefix(3))
                    default: out += dayNames[day.weekday]
                    }
                case .hour(let n):
                    var h = elapsedH ? Int(totalSeconds / 3600) : secondOfDay / 3600
                    if twelveHour && !elapsedH { h = h % 12 == 0 ? 12 : h % 12 }
                    out += pad(h, n)
                case .minute(let n):
                    let m = elapsedM && !elapsedH ? Int(totalSeconds / 60) : Int(totalSeconds / 60 % 60)
                    out += pad(m, n)
                case .second(let n):
                    let s = elapsedS && !elapsedM && !elapsedH ? Int(totalSeconds) : Int(totalSeconds % 60)
                    out += pad(s, n)
                case .elapsedHour(let n): out += pad(Int(totalSeconds / 3600), n)
                case .elapsedMinute(let n): out += pad(elapsedH ? Int(totalSeconds / 60 % 60) : Int(totalSeconds / 60), n)
                case .elapsedSecond(let n): out += pad(elapsedH || elapsedM ? Int(totalSeconds % 60) : Int(totalSeconds), n)
                case .subsecond(let n):
                    let digits = precision == 0 ? "" : String(format: "%0\(precision)lld", subsecondUnits)
                    out += "." + String(digits.prefix(n)) + String(repeating: "0", count: max(0, n - digits.count))
                case .ampm(let full, let lowerA, let lowerP):
                    let pm = secondOfDay >= 43_200
                    if full { out += pm ? "PM" : "AM" } else { out += pm ? (lowerP ? "p" : "P") : (lowerA ? "a" : "A") }
                }
            default: break
            }
        }
        return out
    }

    private static func pad(_ v: Int, _ n: Int) -> String {
        let s = String(v)
        return s.count >= n ? s : String(repeating: "0", count: n - s.count) + s
    }

    /// Calendar day of a whole-day serial as Excel shows it. 1900 system:
    /// day 0 is "January 0, 1900", day 60 is 29 February 1900 (Lotus 1-2-3's
    /// leap-year bug, kept), weekdays as Excel counts them (serial 1 a
    /// Sunday). 1904 system: day 0 is Friday 1 January 1904. Nil past
    /// 9999-12-31.
    static func civilDay(_ days: Int, date1904: Bool) -> (y: Int, m: Int, d: Int, weekday: Int)? {
        guard days >= 0 else { return nil }
        if date1904 {
            let (y, m, d) = ExcelNumberFormat.civil(fromEpochDays: days - 24_107)
            guard y <= 9999 else { return nil }
            return (y, m, d, (days + 5) % 7)
        }
        let weekday = (days + 6) % 7
        if days == 0 { return (1900, 1, 0, weekday) }
        if days == 60 { return (1900, 2, 29, weekday) }
        let (y, m, d) = ExcelNumberFormat.civil(fromEpochDays: days < 60 ? days - 25_568 : days - 25_569)
        guard y <= 9999 else { return nil }
        return (y, m, d, weekday)
    }

    // MARK: - Decimal digits at Excel's precision

    /// A positive number as its 15 significant decimal digits, the way
    /// Excel holds it for display; rounding works on these digits.
    struct Decimal15 {
        var digits: [UInt8]        // significant digits, no leading zero
        var pointPosition: Int     // digits before the decimal point (may be ≤ 0)

        init(_ x: Double) {
            let text = String(format: "%.14e", x)       // "1.23450000000000e+03"
            let parts = text.split(separator: "e")
            let mantissa = parts.first.map(String.init) ?? "0"
            let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            digits = mantissa.compactMap { $0.wholeNumberValue.map(UInt8.init) }
            pointPosition = exponent + 1
            if digits.allSatisfy({ $0 == 0 }) { digits = [0]; pointPosition = 1 }
        }

        private init(digits: [UInt8], pointPosition: Int) { self.digits = digits; self.pointPosition = pointPosition }

        func shifted(by places: Int) -> Decimal15 { Decimal15(digits: digits, pointPosition: pointPosition + places) }

        /// Integer digits (no leading zeros; "" for zero) and exactly `decimals`
        /// fraction digits, rounded half away from zero.
        func rounded(decimals: Int) -> (String, String) {
            let keep = pointPosition + decimals          // digits kept from the significant run
            var kept: [UInt8]
            if keep <= 0 {
                kept = []
                if keep == 0, let first = digits.first, first >= 5 { kept = [1] }
            } else {
                kept = Array(digits.prefix(keep))
                while kept.count < keep { kept.append(0) }
                if keep < digits.count, digits[keep] >= 5 {
                    var k = kept.count - 1
                    while k >= 0 { if kept[k] == 9 { kept[k] = 0; k -= 1 } else { kept[k] += 1; break } }
                    if k < 0 { kept.insert(1, at: 0) }
                }
            }
            // `kept` holds the value × 10^decimals as an integer.
            var all = kept.map { Character(String($0)) }
            if all.count < decimals + 1 { all = Array(repeating: "0", count: decimals + 1 - all.count) + all }
            let intPart = String(all[..<(all.count - decimals)]).drop { $0 == "0" }
            let fracPart = String(all[(all.count - decimals)...])
            return (String(intPart), fracPart)
        }

        /// "d.ddddd" and its power of ten, rounded at `decimals` places.
        func scientific(decimals: Int) -> (String, Int) {
            var exponent = pointPosition - 1
            var (int, frac) = shifted(by: -exponent).rounded(decimals: decimals)
            if int.count > 1 { exponent += 1; (int, frac) = shifted(by: -exponent).rounded(decimals: decimals) }
            return ((int.isEmpty ? "0" : int) + (decimals > 0 ? "." + frac : ""), exponent)
        }
    }
}
