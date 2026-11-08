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
//    [Workbook]   the 1904 date system, defined names (hidden ones marked),
//                 external workbook references (never refreshed)
//    [Sheet: N]   one line per row, "A1: value"; a formula cell shows its
//                 cached value and the formula text decoded from the token
//                 stream (XLSBFormulaDecoder) — "B13: 4 (formula =C13*2)";
//                 shared and array formulas re-based on the cell; a number-
//                 formatted cell rendered as Excel displays it, with the
//                 serial or stored value kept beside it; hidden
//                 rows and columns labelled and still read; hidden and very
//                 hidden sheets say so
//    [Comments: N] the sheet's comments part (comments1.bin, by the sheet's
//                 relationships): "C8: text (author Name)" per comment
//
//  Table parts (xl/tables/*.bin) give structured references their table and
//  column names; an externalLink part gives an external workbook's sheet
//  names and defined names; BrtPlaceholderName gives add-in function names.
//
//  Shared strings come from xl/sharedStrings.bin; sheet names, order and
//  visibility from xl/workbook.bin and its relationships; number formats
//  from xl/styles.bin. Nothing is evaluated; a record this reader does not
//  know is skipped by its size.
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
            let partLimit = ExtractionLimits.effective.partBytes
            guard member.uncompressedSize <= partLimit else {
                skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(partLimit)-byte guard)")
                return nil
            }
            return try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
        }
        /// A part's relationships (XML even in a binary workbook), id → target as written.
        func relationships(of part: String) throws -> [String: (target: String, external: Bool)] {
            let folder = (part as NSString).deletingLastPathComponent
            guard let data = try bytes(folder + "/_rels/" + (part as NSString).lastPathComponent + ".rels") else { return [:] }
            let rels = OOXMLTextCollector(.raw)
            guard rels.parse(data) else { return [:] }
            var out: [String: (String, Bool)] = [:]
            for rel in rels.relationships {
                out[rel.id] = (rel.external ? rel.target : rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : OfficeTextExtractor.resolve(folder, rel.target), rel.external)
            }
            return out
        }
        /// The external workbook an externalLink part points at.
        func externalTarget(of linkPart: String) throws -> String? {
            let rels = try relationships(of: linkPart).values.sorted { $0.target < $1.target }
            return rels.first { $0.external }?.target ?? rels.first?.target
        }

        // Shared strings.
        var shared: [String] = []
        if let sst = try bytes("xl/sharedStrings.bin") {
            for record in records(in: sst) where record.type == 0x0013 {
                var pos = 1   // flags
                if let s = wideString(record.payload, &pos) { shared.append(s) }
            }
        }
        // Styles: number formats and the cell style table (cellXfs index → format).
        var formats: [Int: ExcelNumberFormat.Format] = [:]
        if let styles = try bytes("xl/styles.bin") {
            var codes: [Int: String] = [:]
            var inCellXfs = false
            var index = 0
            for record in records(in: styles) {
                switch record.type {
                case 0x002C:   // BrtFmt: ifmt, stFmtCode
                    guard record.payload.count >= 6 else { continue }
                    var pos = 2
                    if let code = wideString(record.payload, &pos) { codes[Int(u16(record.payload, 0))] = code }
                case 0x0269: inCellXfs = true; index = 0        // BrtBeginCellXFs
                case 0x026A: inCellXfs = false                   // BrtEndCellXFs
                case 0x002F:   // BrtXF: ixfeParent, iFmt, …
                    guard inCellXfs, record.payload.count >= 4 else { continue }
                    let id = Int(u16(record.payload, 2))
                    formats[index] = ExcelNumberFormat.classify(id: id, code: codes[id])
                    index += 1
                default: break
                }
            }
        }
        // Workbook: sheets in order, hidden state, 1904 flag, defined names, the sheet table for 3-D references.
        struct SheetEntry { let name: String; let relID: String; let state: UInt32 }
        var sheets: [SheetEntry] = []
        var date1904 = false
        var context = XLSBFormulaContext()
        var names: [(name: String, hidden: Bool, formula: String)] = []
        var workbookRels: [String: (target: String, external: Bool)] = [:]
        var pendingNames: [(name: String, hidden: Bool, rgce: Data, rgcb: Data)] = []
        if let workbook = try bytes("xl/workbook.bin") {
            workbookRels = try relationships(of: "xl/workbook.bin")
            for record in records(in: workbook) {
                let p = record.payload
                switch record.type {
                case 0x009C:   // BrtBundleSh: hsState, iTabID, strRelID, strName
                    guard p.count >= 8 else { continue }
                    let state = u32(p, 0)
                    var relID = ""
                    var name = ""
                    // Excel 2007-era files (Tika's testEXCEL.xlsb) carry four more bytes before the strings;
                    // the layout that yields a readable name wins.
                    for start in [8, 12] {
                        var pos = start
                        var id: String? = nil
                        if u32(p, pos) == 0xFFFF_FFFF { pos += 4 } else { guard let read = wideString(p, &pos) else { continue }; id = read }
                        guard let read = wideString(p, &pos), !read.isEmpty else { continue }
                        relID = id ?? ""; name = read
                        break
                    }
                    sheets.append(SheetEntry(name: name, relID: relID, state: state))
                case 0x0099:   // BrtWbProp
                    if p.count >= 4, u32(p, 0) & 0x1 != 0 { date1904 = true }
                case 0x0027:   // BrtName: flags, chKey, itab, name, formula, comment
                    guard p.count >= 13 else { continue }
                    let hidden = u32(p, 0) & 0x1 != 0
                    var pos = 9
                    guard let name = wideString(p, &pos), let formula = parsedFormula(p, &pos) else { continue }
                    pendingNames.append((name, hidden, formula.rgce, formula.rgcb))
                case 0x0163:   // BrtSupBookSrc: the relationship of an externalLink part
                    var pos = 0
                    let relID = nullableWideString(p, &pos) ?? ""
                    var target: String? = nil
                    var tabs: [String] = []
                    if let link = workbookRels[relID]?.target {
                        target = try externalTarget(of: link) ?? link
                        // The link part names the other workbook's sheets (BrtSupTabs) and the defined
                        // names formulas reach through PtgNameX (BrtSupNameStart, in order).
                        if let linkData = try bytes(link) {
                            var linkNames: [String] = []
                            for linkRecord in records(in: linkData) {
                                var at = 0
                                switch linkRecord.type {
                                case 0x0167:   // BrtSupTabs: cTab, then the sheet names
                                    guard linkRecord.payload.count >= 4 else { continue }
                                    at = 4
                                    tabs = []
                                    for _ in 0..<Int(u32(linkRecord.payload, 0)) { guard let tab = wideString(linkRecord.payload, &at) else { break }; tabs.append(tab) }
                                case 0x0241:   // BrtSupNameStart: the external defined name
                                    linkNames.append(wideString(linkRecord.payload, &at) ?? "")
                                default: break
                                }
                            }
                            if !linkNames.isEmpty { context.supNames[context.supBooks.count] = linkNames }
                        }
                    }
                    context.supBooks.append(.external(target: target, tabs: tabs))
                case 0x029B: context.supBooks.append(.addIn)      // BrtSupAddin ([MS-XLSB] record 667)
                case 0x0169:   // BrtPlaceholderName: an add-in function (after BrtSupAddin) or a name (after BrtSupSame)
                    var pos = 0
                    if let last = context.supBooks.indices.last, let name = wideString(p, &pos) { context.supNames[last, default: []].append(name) }
                case 0x0165: context.supBooks.append(.selfBook)   // BrtSupSelf
                case 0x0166: context.supBooks.append(.sameSheet)  // BrtSupSame
                case 0x0167:   // BrtSupTabs: the sheet names of the external workbook just declared
                    guard p.count >= 4 else { continue }
                    var pos = 4
                    var tabs: [String] = []
                    for _ in 0..<Int(u32(p, 0)) { guard let tab = wideString(p, &pos) else { break }; tabs.append(tab) }
                    if let last = context.supBooks.indices.last, case .external(let target, _) = context.supBooks[last] {
                        context.supBooks[last] = .external(target: target, tabs: tabs)
                    }
                case 0x016A:   // BrtExternSheet: cXti, then XTI (iSupBook, itabFirst, itabLast)
                    guard p.count >= 4 else { continue }
                    let count = Int(u32(p, 0))
                    var pos = 4
                    for _ in 0..<count {
                        guard pos + 12 <= p.count else { break }
                        context.externSheets.append((Int(Int32(bitPattern: u32(p, pos))), Int(Int32(bitPattern: u32(p, pos + 4))), Int(Int32(bitPattern: u32(p, pos + 8)))))
                        pos += 12
                    }
                default: break
                }
            }
        }
        context.sheetNames = sheets.map(\.name)
        context.definedNames = pendingNames.map(\.name)
        // Tables (xl/tables/*.bin): PtgList names a table by its workbook-wide idList.
        for part in parts.keys.filter({ $0.hasPrefix("xl/tables/") && $0.hasSuffix(".bin") && !$0.contains("/_rels/") }).sorted() {
            guard let data = try bytes(part) else { continue }
            for table in tables(in: data) { context.tables[table.id] = table }
        }
        for pending in pendingNames {
            let text = XLSBFormulaDecoder.decode(rgce: pending.rgce, rgcb: pending.rgcb, base: nil, context: context)
            names.append((pending.name, pending.hidden, text))
        }
        var targetByID: [String: String] = [:]
        for (id, rel) in workbookRels { targetByID[id] = rel.target }
        let sheetFiles = parts.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".bin") }
            .sorted { OfficeTextExtractor.sheetNumber($0) < OfficeTextExtractor.sheetNumber($1) }
        if sheetFiles.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }

        var text = ""
        var components: [String] = []
        var workbookLines: [String] = []
        if date1904 { workbookLines.append("1904 date system: serial dates count from 1 January 1904") }
        for name in names {
            workbookLines.append((name.hidden ? "[hidden name \(name.name)]" : "name \(name.name)") + (name.formula.isEmpty ? "" : ": " + name.formula))
        }
        for link in parts.keys.filter({ $0.hasPrefix("xl/externalLinks/externalLink") && !$0.contains("/_rels/") })
            .sorted(by: { OfficeTextExtractor.sheetNumber($0) < OfficeTextExtractor.sheetNumber($1) }) {
            workbookLines.append("[external reference: \(try externalTarget(of: link) ?? link)] not refreshed")
        }
        if !workbookLines.isEmpty {
            components.append("Workbook")
            text += "[Workbook]\n" + workbookLines.joined(separator: "\n") + "\n\n"
        }
        // Sheets in workbook order when the relationships resolve, file order otherwise.
        var ordered: [(file: String, entry: SheetEntry?)] = []
        var seen = Set<String>()
        for entry in sheets { if let file = targetByID[entry.relID], parts[file] != nil { ordered.append((file, entry)); seen.insert(file) } }
        for file in sheetFiles where !seen.contains(file) { ordered.append((file, nil)) }
        for (file, entry) in ordered {
            guard let data = try bytes(file) else { continue }
            var label = "Sheet: " + (entry?.name ?? "Sheet \(OfficeTextExtractor.sheetNumber(file))")
            if let state = entry?.state { if state == 2 { label += " (very hidden)" } else if state != 0 { label += " (hidden)" } }
            components.append(label)
            text += "[\(label)]\n" + sheetText(data, shared: shared, formats: formats, date1904: date1904, context: context) + "\n"
            // Cell comments attached to this sheet by its relationships — the same section the XLSX reader writes.
            let sheetName = entry?.name ?? "Sheet \(OfficeTextExtractor.sheetNumber(file))"
            for rel in try relationships(of: file).values.sorted(by: { $0.target < $1.target })
            where !rel.external && rel.target.hasSuffix(".bin") && (rel.target as NSString).lastPathComponent.hasPrefix("comments") {
                guard let data = try bytes(rel.target) else { continue }
                let body = commentsText(data)
                if !body.isEmpty {
                    components.append("Comments: " + sheetName)
                    text += "[Comments: \(sheetName)]\n" + body + "\n"
                }
            }
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

    /// A shared (BrtShrFmla) or array (BrtArrFmla) formula and the range it covers.
    struct RangeFormula {
        let rowFirst: Int, rowLast: Int, columnFirst: Int, columnLast: Int
        let rgce: Data, rgcb: Data
        let array: Bool
        func contains(row: Int, column: Int) -> Bool { row >= rowFirst && row <= rowLast && column >= columnFirst && column <= columnLast }
    }

    /// One worksheet part as "A1: value" rows.
    static func sheetText(_ data: Data, shared: [String], formats: [Int: ExcelNumberFormat.Format] = [:], date1904: Bool = false,
                          context: XLSBFormulaContext = XLSBFormulaContext()) -> String {
        let all = records(in: data)
        // Pass 1: shared and array formulas, so a cell that points at one (PtgExp) can be rendered wherever it sits.
        var rangeFormulas: [RangeFormula] = []
        for record in all where record.type == 0x01AA || record.type == 0x01AB {
            let p = record.payload
            guard p.count >= 16 else { continue }
            var pos = record.type == 0x01AA ? 17 : 16   // BrtArrFmla has a flags byte after the range
            guard let formula = parsedFormula(p, &pos) else { continue }
            rangeFormulas.append(RangeFormula(rowFirst: Int(u32(p, 0)), rowLast: Int(u32(p, 4)), columnFirst: Int(u32(p, 8)), columnLast: Int(u32(p, 12)),
                                              rgce: formula.rgce, rgcb: formula.rgcb, array: record.type == 0x01AA))
        }
        // Pass 2: rows and cells.
        var lines: [String] = []
        var row = 0
        var rowHidden = false
        var hiddenColumns = Set<Int>()
        var cells: [String] = []
        func flush() {
            if !cells.isEmpty { lines.append((rowHidden ? "[hidden row \(row + 1)] " : "") + cells.joined(separator: "\t")); cells = [] }
        }
        for record in all {
            let p = record.payload
            switch record.type {
            case 0x0000:   // BrtRowHdr: rw, ixfe, miyRw, flags (fDyZero = hidden), …
                flush()
                if p.count >= 4 { row = Int(u32(p, 0)) }
                rowHidden = p.count >= 12 && p[p.startIndex + 11] & 0x10 != 0
            case 0x003C:   // BrtColInfo: colFirst, colLast, coldx, ixfe, flags (fHidden)
                if p.count >= 18, u16(p, 16) & 0x1 != 0 {
                    let first = Int(u32(p, 0)), last = Int(u32(p, 4))
                    if first >= 0, last >= first { for column in first...min(last, ExcelFormulaText.maxColumn - 1) { hiddenColumns.insert(column) } }
                }
            case 0x0001...0x000B:
                guard p.count >= 8 else { continue }
                let column = Int(u32(p, 0))
                let styleIndex = Int(u32(p, 4) & 0x00FF_FFFF)
                let address = OfficeTextExtractor.columnName(column) + String(row + 1)
                var value = ""
                var isNumber = false
                var formulaAt: Int? = nil
                switch record.type {
                case 0x0001: continue                                        // BrtCellBlank
                case 0x0002: if p.count >= 12 { value = rk(u32(p, 8)); isNumber = true }   // BrtCellRk
                case 0x0003: if p.count >= 9 { value = errorName(p[p.startIndex + 8]) }
                case 0x0004: if p.count >= 9 { value = p[p.startIndex + 8] == 0 ? "FALSE" : "TRUE" }
                case 0x0005: if p.count >= 16 { value = number(f64(p, 8)); isNumber = true }
                case 0x0006: var pos = 8; value = wideString(p, &pos) ?? ""   // BrtCellSt
                case 0x0007:                                                 // BrtCellIsst
                    if p.count >= 12 { let i = Int(u32(p, 8)); value = i >= 0 && i < shared.count ? shared[i] : "" }
                case 0x0008: var pos = 8; value = wideString(p, &pos) ?? ""; formulaAt = pos + 2   // BrtFmlaString
                case 0x0009: if p.count >= 16 { value = number(f64(p, 8)); isNumber = true }; formulaAt = 18   // BrtFmlaNum
                case 0x000A: if p.count >= 9 { value = p[p.startIndex + 8] == 0 ? "FALSE" : "TRUE" }; formulaAt = 11   // BrtFmlaBool
                case 0x000B: if p.count >= 9 { value = errorName(p[p.startIndex + 8]) }; formulaAt = 11                 // BrtFmlaError
                default: continue
                }
                var formulaNote: String? = nil
                if var pos = formulaAt {
                    if let formula = parsedFormula(p, &pos) {
                        formulaNote = formula.rgce.isEmpty ? "formula not stored"
                            : "formula =" + formulaText(formula.rgce, formula.rgcb, row: row, column: column, rangeFormulas: rangeFormulas, context: context)
                    } else {
                        formulaNote = "formula not decoded: record truncated"
                    }
                }
                let cell = OfficeTextExtractor.cellText(value: value, isNumber: isNumber, format: formats[styleIndex], date1904: date1904, formulaNote: formulaNote)
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    cells.append((hiddenColumns.contains(column) ? "[hidden column \(OfficeTextExtractor.columnName(column))] " : "") + address + ": " + trimmed)
                }
            default: break
            }
        }
        flush()
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// The A1 text of a cell's formula; a PtgExp cell is rendered from the shared or array formula covering it.
    static func formulaText(_ rgce: Data, _ rgcb: Data, row: Int, column: Int, rangeFormulas: [RangeFormula], context: XLSBFormulaContext) -> String {
        let base = XLSBFormulaDecoder.Base(row: row, column: column)
        if let master = XLSBFormulaDecoder.sharedFormulaMaster(rgce: rgce, rgcb: rgcb) {
            // The formula whose first cell is the master PtgExp names wins: a cell inside a shared
            // formula's range can also be the top-left cell of an array formula (bug66682.xlsb, C9).
            if let range = rangeFormulas.first(where: { $0.rowFirst == master.row && $0.columnFirst == master.column })
                ?? rangeFormulas.first(where: { $0.contains(row: row, column: column) }) {
                let text = XLSBFormulaDecoder.decode(rgce: range.rgce, rgcb: range.rgcb, base: base, context: context)
                return range.array ? text + " (array formula)" : text
            }
            return "(shared formula of \(OfficeTextExtractor.columnName(master.column))\(master.row + 1) not found in this sheet)"
        }
        return XLSBFormulaDecoder.decode(rgce: rgce, rgcb: rgcb, base: base, context: context)
    }

    /// A comments part ([MS-XLSB] 2.1.7.8): BrtCommentAuthor (632) records list the authors;
    /// each BrtBeginComment (635: iauthor, UncheckedRfX, guid) + BrtCommentText (637: RichStr)
    /// + BrtEndComment (636) is one cell's comment. One line per comment, in file order:
    /// "A1: text (author Name)" — the XLSX reader's "A1: text" with the author the binary
    /// format stores beside the text. Excel often also starts the text with "Name:".
    static func commentsText(_ data: Data) -> String {
        var authors: [String] = []
        var author = -1
        var reference = ""
        var body: String? = nil
        var text = ""
        for record in records(in: data) {
            let p = record.payload
            switch record.type {
            case 0x0278:   // BrtCommentAuthor: XLWideString
                var pos = 0
                authors.append(wideString(p, &pos) ?? "")
            case 0x027B:   // BrtBeginComment
                guard p.count >= 20 else { continue }
                author = Int(Int32(bitPattern: u32(p, 0)))
                reference = OfficeTextExtractor.columnName(Int(u32(p, 12))) + String(Int(u32(p, 4)) + 1)
                body = nil
            case 0x027D:   // BrtCommentText: RichStr — flags (fRichStr, fExtStr), then XLWideString; runs and phonetics follow
                var pos = 1
                body = wideString(p, &pos)
            case 0x027C:   // BrtEndComment
                let trimmed = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = author >= 0 && author < authors.count ? authors[author] : ""
                if !trimmed.isEmpty || !name.isEmpty {
                    text += (reference.isEmpty ? "" : reference + ": ") + trimmed + (name.isEmpty ? "" : " (author \(name))") + "\n"
                }
                author = -1; reference = ""; body = nil
            default: break
            }
        }
        return text
    }

    /// A table part ([MS-XLSB] 2.1.7.51): BrtBeginList (343) — rfxList (16), lt, idList, crwHeader,
    /// crwTotals, flags, six DXF ids, dwConnID (4 each), then stName and stDisplayName
    /// (XLNullableWideString) — and its BrtBeginListCol (347) records — idField, ilta, three DXF
    /// ids, idqsif (4 each), then stName and stCaption; the caption is the name formulas show.
    static func tables(in data: Data) -> [XLSBFormulaContext.Table] {
        var out: [XLSBFormulaContext.Table] = []
        var current: (id: Int, name: String, rfx: [Int])? = nil
        var columns: [String] = []
        func finish() {
            if let table = current {
                out.append(.init(id: table.id, name: table.name, columns: columns,
                                 rowFirst: table.rfx[0], rowLast: table.rfx[1], columnFirst: table.rfx[2], columnLast: table.rfx[3]))
            }
            current = nil; columns = []
        }
        for record in records(in: data) {
            let p = record.payload
            switch record.type {
            case 0x0157:   // BrtBeginList
                finish()
                guard p.count >= 64 else { continue }
                var pos = 64
                let programmatic = nullableWideString(p, &pos)
                let display = nullableWideString(p, &pos)
                current = (Int(u32(p, 20)), display ?? programmatic ?? "Table\(u32(p, 20))", (0..<4).map { Int(u32(p, $0 * 4)) })
            case 0x015B:   // BrtBeginListCol
                guard current != nil, p.count >= 24 else { continue }
                var pos = 24
                let name = nullableWideString(p, &pos)
                let caption = nullableWideString(p, &pos)
                columns.append(caption ?? name ?? "Column\(columns.count + 1)")
            case 0x0158: finish()   // BrtEndList
            default: break
            }
        }
        finish()
        return out
    }

    /// CellParsedFormula / NameParsedFormula: cce, rgce, cb, rgcb.
    static func parsedFormula(_ data: Data, _ pos: inout Int) -> (rgce: Data, rgcb: Data)? {
        guard pos + 4 <= data.count else { return nil }
        let cce = Int(u32(data, pos)); pos += 4
        guard cce >= 0, pos + cce <= data.count else { return nil }
        let rgce = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + cce)); pos += cce
        guard pos + 4 <= data.count else { return (rgce, Data()) }
        let cb = Int(u32(data, pos)); pos += 4
        guard cb >= 0, pos + cb <= data.count else { return (rgce, Data()) }
        let rgcb = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + cb)); pos += cb
        return (rgce, rgcb)
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
        case 0x2B: return "#GETTING_DATA"
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

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let b = data.startIndex + offset
        return UInt16(data[b]) | (UInt16(data[b + 1]) << 8)
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
