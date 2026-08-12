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
