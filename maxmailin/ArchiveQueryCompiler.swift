//
//  ArchiveQueryCompiler.swift
//  maxmailin
//
//  §13.1: ONE compiler from the user-facing search syntax to a structured
//  `EmailQuery`. The legacy operators keep working:
//
//    from:alice@x.com  to:bob@y.com  subject:report  has:attachment
//    before:2024-01-31  after:2023-06-01  type:sent  tag:Important
//    domain:example.com  evidence:Privileged  is:pinned  in:trash
//
//  Remaining words become FTS free text (Boolean/NEAR are handled downstream
//  by FTSQueryBuilder). Natural-language helpers should produce EmailQuery
//  through here — never by mutating arrays.
//

import Foundation

enum ArchiveQueryCompiler {

    /// Compile a user search string (+ optional structured UI state) into an
    /// EmailQuery. Every recognized operator maps to a query field; nothing
    /// is silently dropped — unrecognized `key:value` tokens stay in the free
    /// text so the user can see they were searched literally.
    static func compile(_ input: String, base: EmailQuery = .all) -> EmailQuery {
        var query = base
        var freeText: [String] = []

        for token in tokenize(input) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                freeText.append(token)
                continue
            }
            let key = token[token.startIndex..<colon].lowercased()
            var value = String(token[token.index(after: colon)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "from":
                query.sender = value
            case "to":
                query.recipient = value.lowercased()
            case "subject":
                query.subjectContains = value
            case "domain":
                query.domain = value.lowercased()
            case "tag", "label":
                query.userTag = value
            case "evidence":
                query.evidenceTag = value
            case "type":
                query.messageType = value.lowercased()
            case "has":
                if value.lowercased() == "attachment" || value.lowercased() == "attachments" {
                    query.hasAttachments = true
                } else { freeText.append(token) }
            case "no":
                if value.lowercased() == "attachment" || value.lowercased() == "attachments" {
                    query.hasAttachments = false
                } else { freeText.append(token) }
            case "is":
                switch value.lowercased() {
                case "pinned", "starred": query.pinnedOnly = true
                default: freeText.append(token)
                }
            case "in":
                if value.lowercased() == "trash" { query.includeTrashed = true }
                else { freeText.append(token) }
            case "before":
                if let date = parseDate(value) { query.beforeDate = date }
                else { freeText.append(token) }
            case "after":
                if let date = parseDate(value) { query.afterDate = date }
                else { freeText.append(token) }
            case "sort":
                if let sort = parseSort(value) { query.sort = sort }
                else { freeText.append(token) }
            default:
                freeText.append(token)
            }
        }

        let text = freeText.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        query.text = text.isEmpty ? nil : text
        return query
    }

    /// Split on whitespace, keeping `key:"quoted value"` together.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in input {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func parseSort(_ value: String) -> EmailSortOrder? {
        switch value.lowercased() {
        case "newest", "date", "datedesc": return .dateDesc
        case "oldest", "dateasc": return .dateAsc
        case "subject", "az": return .subjectAZ
        case "size", "largest": return .sizeDesc
        case "priority": return .priorityDesc
        default: return nil
        }
    }
}
