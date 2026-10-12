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
//    filename:invoice.pdf  (or attachment:pdf)  source:takeout.mbox
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
    /// §3-Q4 switch, pushed by the app.
    nonisolated(unsafe) static var exclusionsEnabled = false

    /// `-key:value` or `NOT key:value` → an exclusion, when supported.
    static func exclusion(key: String, value: String) -> EmailExclusion? {
        switch key {
        case "from": return EmailExclusion(field: .sender, value: value)
        case "to": return EmailExclusion(field: .recipient, value: value.lowercased())
        case "subject": return EmailExclusion(field: .subject, value: value)
        case "domain": return EmailExclusion(field: .domain, value: value.lowercased())
        case "tag", "label": return EmailExclusion(field: .tag, value: value)
        case "has":
            let v = value.lowercased()
            return (v == "attachment" || v == "attachments") ? EmailExclusion(field: .attachments, value: "") : nil
        case "source": return value.isEmpty ? nil : EmailExclusion(field: .source, value: value)
        case "evidence": return value.isEmpty ? nil : EmailExclusion(field: .evidence, value: value)
        case "type": return value.isEmpty ? nil : EmailExclusion(field: .type, value: value.lowercased())
        case "filename", "attachment": return value.isEmpty ? nil : EmailExclusion(field: .filename, value: value)
        case "before", "after":
            guard let date = parseDate(value) else { return nil }
            let epoch = String(Int64(date.timeIntervalSince1970.rounded()))
            return EmailExclusion(field: key == "before" ? .before : .after, value: epoch)
        case "is":
            let v = value.lowercased()
            if v == "recovered" || v == "deleted" { return EmailExclusion(field: .recovered, value: "") }
            return (v == "pinned" || v == "starred") ? EmailExclusion(field: .pinned, value: "") : nil
        case "recovery":
            return recoveryState(value).map { EmailExclusion(field: .recovered, value: $0) }
        default: return nil
        }
    }

    static func compile(_ input: String, base: EmailQuery = .all,
                        exclusions exclusionsOn: Bool = exclusionsEnabled) -> EmailQuery {
        var query = base
        var freeText: [String] = []
        var negateNext = false

        for token0 in tokenize(input) {
            var token = token0
            if exclusionsOn {
                if token.uppercased() == "NOT" { negateNext = true; continue }
                var negated = negateNext
                negateNext = false
                if token.hasPrefix("-"), token.contains(":") { negated = true; token.removeFirst() }
                if negated, let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                    let key = token[token.startIndex..<colon].lowercased()
                    var value = String(token[token.index(after: colon)...])
                    if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                    if let ex = exclusion(key: key, value: value) {
                        query.exclusions = (query.exclusions ?? []) + [ex]
                        continue
                    }
                    // A negated operator with no exclusion form (-source:,
                    // -before: …) must never fall through to the INCLUDE
                    // parser below — that would keep exactly what was asked
                    // to be left out. It stays literal text, like any
                    // unrecognised operator.
                    freeText.append(token0)
                    continue
                }
                if negated, !token.contains(":") { freeText.append("NOT") }
            }
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
            case "source":
                query.sourceFileName = value
            case "evidence":
                query.evidenceTag = value
            case "type":
                query.messageType = value.lowercased()
            case "has":
                if value.lowercased() == "attachment" || value.lowercased() == "attachments" {
                    query.hasAttachments = true
                } else { freeText.append(token) }
            case "filename", "attachment":
                // A7: attachment file name or extension contains.
                if !value.isEmpty {
                    query.attachmentFilename = value
                    query.hasAttachments = true
                } else { freeText.append(token) }
            case "no":
                if value.lowercased() == "attachment" || value.lowercased() == "attachments" {
                    query.hasAttachments = false
                } else { freeText.append(token) }
            case "is":
                switch value.lowercased() {
                case "pinned", "starred": query.pinnedOnly = true
                case "recovered", "deleted": query.recovery = "any"   // 3.1 R2
                default: freeText.append(token)
                }
            case "recovery":
                if let state = recoveryState(value) { query.recovery = state } else { freeText.append(token) }
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

    /// `recovery:unpurged`, `recovery:orphan`, `recovery:deleted` (deleted folder) …
    static func recoveryState(_ value: String) -> String? {
        switch value.lowercased() {
        case "deleted", "deletedfolder", "trash": return RecoveryState.deletedFolder.rawValue
        case "flagged", "flaggeddeleted": return RecoveryState.flaggedDeleted.rawValue
        case "unpurged", "expunged": return RecoveryState.unpurged.rawValue
        case "orphan", "orphans": return RecoveryState.orphan.rawValue
        case "carved": return RecoveryState.carved.rawValue
        case "stub", "stubs": return RecoveryState.deletionStub.rawValue
        case "any", "all": return "any"
        default: return nil
        }
    }
}
