@testable import ArchiveCore
//
//  DocumentTable.swift
//  maxmailin
//
//  SAP-style structured document data. A captured job is stored as typed
//  key/value fields grouped into sections (not a text blob), so opening a
//  document shows a spreadsheet-like table of every data point on the page,
//  exportable to CSV (Excel) and manipulable into custom reports later.
//
//  Two on-disk forms are supported so this works for EVERY document:
//   • application/json  → an exact CapturedDocument (maximum fidelity)
//   • text/markdown     → best-effort parsed into rows ("Key: value" lines),
//                         so legacy/text payloads still tabulate & export.
//

import Foundation

/// The exact structured form written for new captures.
struct CapturedDocument: Codable, Equatable {
    var title: String
    var sections: [Section]

    struct Section: Codable, Equatable {
        var name: String
        var fields: [Field]
    }
    struct Field: Codable, Equatable {
        var key: String
        var value: String
    }

    func jsonString() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func from(json: String) -> CapturedDocument? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CapturedDocument.self, from: data)
    }

    /// A human-readable rendering of the same structured data — so we keep
    /// BOTH forms (table for manipulation, prose for reading) from one payload.
    func plainText() -> String {
        var out = "\(title)\n" + String(repeating: "=", count: max(3, title.count)) + "\n\n"
        for section in sections {
            out += "\(section.name)\n"
            for f in section.fields { out += "  \(f.key): \(f.value)\n" }
            out += "\n"
        }
        return out
    }
}

/// A rendered, display/export-ready table derived from a document payload.
struct DocumentTable: Equatable {
    struct Row: Equatable { let key: String; let value: String }
    struct Section: Equatable { let name: String; let rows: [Row] }
    let sections: [Section]

    var isEmpty: Bool { sections.allSatisfy { $0.rows.isEmpty } }
    var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }

    /// Build a table from a stored payload, whichever form it's in.
    static func parse(contentType: String, body: String) -> DocumentTable {
        if contentType.contains("json"), let doc = CapturedDocument.from(json: body) {
            return DocumentTable(sections: doc.sections.map { s in
                Section(name: s.name, rows: s.fields.map { Row(key: $0.key, value: $0.value) })
            })
        }
        return parseText(body)
    }

    /// Best-effort tabulation of a plain-text payload: lines shaped like
    /// "Key: value" become rows; a short all-caps / heading-like line starts a
    /// new section; anything else is a note row.
    static func parseText(_ body: String) -> DocumentTable {
        var sections: [(name: String, rows: [Row])] = []
        var current = "Details"
        var rows: [Row] = []
        func flush() {
            if !rows.isEmpty { sections.append((current, rows)); rows = [] }
        }
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Skip rule lines like "====" / "----".
            if line.allSatisfy({ $0 == "=" || $0 == "-" }) { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && key.count <= 60 {
                    rows.append(Row(key: key, value: value))
                    continue
                }
            }
            // A heading-like line (no key/value): start a new section.
            let isHeading = line == line.uppercased() && line.count <= 60
            if isHeading {
                flush()
                current = line.capitalized
            } else {
                rows.append(Row(key: "•", value: line))
            }
        }
        flush()
        return DocumentTable(sections: sections.map { Section(name: $0.name, rows: $0.rows) })
    }

    /// Excel-ready CSV: Section,Field,Value with proper quoting.
    func csv() -> String {
        func esc(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var out = "Section,Field,Value\n"
        for section in sections {
            for row in section.rows {
                out += [section.name, row.key, row.value].map(esc).joined(separator: ",") + "\n"
            }
        }
        return out
    }
}

/// A customized report built across MANY documents: one row per document,
/// columns = the union of their field keys. The substrate for "pull all the
/// verdicts / privilege counts / whatever into one spreadsheet."
enum CrossDocumentReport {
    struct Result: Equatable {
        var columns: [String]
        var rows: [[String]]
        /// Earliest … latest source-document date (nil when empty).
        var period: ClosedRange<Date>? = nil
        var isEmpty: Bool { rows.isEmpty }
    }

    /// The leading columns every report carries.
    static let fixedColumns = ["Document", "Date"]

    /// First section name of a saved cross-document report — lets a Report
    /// (RPT) report skip earlier cross-document reports instead of exploding
    /// their per-document sections into hundreds of columns.
    static let reportSectionName = "Cross-document report"

    static func isCrossDocumentReport(_ table: DocumentTable) -> Bool {
        table.sections.first?.name == reportSectionName
    }

    /// ISO calendar date: sorts correctly in a spreadsheet and reads the same
    /// in every locale (a short style gives 12/08/26 — August or December?).
    static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `docs`: (documentNumber, date, its parsed table). Keys keep first-seen
    /// order; a doc missing a key gets a blank cell. Seal sections are left
    /// out (signatures are not report data). A field named like a fixed
    /// column is dropped when it only repeats the document number, otherwise
    /// kept as "<name> (field)"; a label repeated in another section with a
    /// different value is kept as "<section> › <label>" rather than lost.
    static func build(_ docs: [(number: String, date: Date, table: DocumentTable)]) -> Result {
        var keyOrder: [String] = []
        var seen = Set<String>()
        var perDoc: [[String: String]] = []
        for d in docs {
            var flat: [String: String] = [:]
            for section in d.table.sections where section.name != DocumentRegistry.receiptSectionName {
                for row in section.rows where row.key != "•" {
                    var key = row.key
                    if fixedColumns.contains(key) {
                        if row.value == d.number { continue }
                        key += " (field)"
                    }
                    if let existing = flat[key] {
                        if existing == row.value { continue }
                        key = "\(section.name) › \(key)"
                        var n = 2
                        let base = key
                        while flat[key] != nil { key = "\(base) (\(n))"; n += 1 }
                    }
                    flat[key] = row.value
                    if !seen.contains(key) { seen.insert(key); keyOrder.append(key) }
                }
            }
            perDoc.append(flat)
        }
        var rows: [[String]] = []
        for (i, d) in docs.enumerated() {
            var row = [d.number, isoDay(d.date)]
            for k in keyOrder { row.append(perDoc[i][k] ?? "") }
            rows.append(row)
        }
        let dates = docs.map(\.date)
        let period = dates.min().flatMap { lo in dates.max().map { lo...$0 } }
        return Result(columns: fixedColumns + keyOrder, rows: rows, period: period)
    }

    // MARK: Summary

    struct Breakdown: Equatable {
        struct Count: Equatable { let value: String; let count: Int }
        let column: String
        let counts: [Count]
    }

    static let blankLabel = "(blank)"

    /// Counts per value for the categorical columns — those whose values
    /// repeat across documents (Status, Workflow, Hash algorithm…). Free-text
    /// columns where nearly every value is unique are not summarised;
    /// `maxDistinct` only decides what reads as a category, no data is cut.
    static func breakdowns(_ r: Result, maxDistinct: Int = 12) -> [Breakdown] {
        var out: [Breakdown] = []
        for (c, column) in r.columns.enumerated() where c >= fixedColumns.count {
            let values = r.rows.map { c < $0.count ? $0[c] : "" }
            let filled = values.filter { !$0.isEmpty }
            let distinct = Set(filled)
            guard filled.count >= 2, distinct.count <= maxDistinct, distinct.count < filled.count else { continue }
            var tally: [String: Int] = [:]
            for v in values { tally[v.isEmpty ? blankLabel : v, default: 0] += 1 }
            let counts = tally.map { Breakdown.Count(value: $0.key, count: $0.value) }
                .sorted {
                    if ($0.value == blankLabel) != ($1.value == blankLabel) { return $1.value == blankLabel }
                    return $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value
                }
            out.append(Breakdown(column: column, counts: counts))
        }
        return out
    }

    // MARK: The saved report

    /// The report as a structured document (sealed on capture): header facts,
    /// the summary counts, then one section per source document carrying
    /// every non-blank cell — so opening the RPT reproduces the full table.
    static func capturedDocument(_ r: Result, typeName: String, builtBy: String,
                                 builtAt: Date) -> CapturedDocument {
        typealias F = CapturedDocument.Field
        var header: [F] = [
            F(key: "Document type", value: typeName),
            F(key: "Documents included", value: String(r.rows.count)),
        ]
        if let p = r.period {
            header.append(F(key: "Earliest document", value: isoDay(p.lowerBound)))
            header.append(F(key: "Latest document", value: isoDay(p.upperBound)))
        }
        header.append(F(key: "Columns", value: String(r.columns.count)))
        header.append(F(key: "Built at", value: ISO8601DateFormatter().string(from: builtAt)))
        header.append(F(key: "Built by", value: builtBy.isEmpty ? "—" : builtBy))

        var sections = [CapturedDocument.Section(name: reportSectionName, fields: header)]
        let summary = breakdowns(r).flatMap { b in
            b.counts.map { F(key: "\(b.column): \($0.value)", value: String($0.count)) }
        }
        if !summary.isEmpty { sections.append(.init(name: "Summary", fields: summary)) }
        for row in r.rows {
            var fields: [F] = []
            for (c, column) in r.columns.enumerated() where c > 0 && c < row.count && !row[c].isEmpty {
                fields.append(F(key: column, value: row[c]))
            }
            sections.append(.init(name: row.first ?? "", fields: fields))
        }
        return CapturedDocument(title: "\(typeName) — \(reportSectionName)", sections: sections)
    }

    /// One-line description posted with the RPT number.
    static func summaryLine(_ r: Result, typeName: String) -> String {
        var s = "\(typeName) report — \(r.rows.count) document\(r.rows.count == 1 ? "" : "s")"
        if let p = r.period { s += " (\(isoDay(p.lowerBound)) → \(isoDay(p.upperBound)))" }
        return s
    }

    /// Printable form for the PDF: header, summary counts, then each source
    /// document as a block of "Field: value" lines (a 15-column grid does not
    /// fit a page; blocks keep every value readable).
    static func pdfLines(_ r: Result, number: String, typeName: String, builtBy: String,
                         builtAt: Date, sealSHA256: String?) -> [String] {
        var lines = ["\(typeName.uppercased()) — CROSS-DOCUMENT REPORT", ""]
        lines.append("Report:     \(number)")
        lines.append("Documents:  \(r.rows.count) \(typeName)")
        if let p = r.period { lines.append("Period:     \(isoDay(p.lowerBound)) → \(isoDay(p.upperBound))") }
        let built = ISO8601DateFormatter().string(from: builtAt)
        lines.append("Built:      \(built)\(builtBy.isEmpty ? "" : " by \(builtBy)")")
        if let sealSHA256 { lines.append("Seal:       SHA-256 \(sealSHA256)") }
        let summary = breakdowns(r)
        if !summary.isEmpty {
            lines += ["", "SUMMARY"]
            for b in summary {
                lines.append("  \(b.column)")
                for c in b.counts { lines.append("    \(c.value): \(c.count)") }
            }
        }
        lines += ["", "DOCUMENTS"]
        for row in r.rows {
            lines.append("")
            lines.append(row.count > 1 ? "\(row[0])  ·  \(row[1])" : row.first ?? "")
            for (c, column) in r.columns.enumerated() where c >= fixedColumns.count && c < row.count && !row[c].isEmpty {
                lines.append("  \(column): \(row[c])")
            }
        }
        return lines
    }

    static func csv(_ r: Result) -> String {
        func esc(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var out = r.columns.map(esc).joined(separator: ",") + "\n"
        for row in r.rows { out += row.map(esc).joined(separator: ",") + "\n" }
        return out
    }
}
