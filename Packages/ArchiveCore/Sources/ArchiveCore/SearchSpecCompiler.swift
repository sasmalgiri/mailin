//
//  SearchSpecCompiler.swift
//  ArchiveCore
//
//  Five jobs FIND-04/06 (plan §5.3.4): `SearchSpec` → SQL WHERE fragments
//  with bound values. Structure comes from this file's allowlist; every user
//  value is a bind; text that reaches FTS5 MATCH is quoted as a literal
//  token so no input can change the query's shape. The email row is `e`.
//
//  Three-valued evaluation (plan rules 8–10): a text condition can only be
//  answered where the relevant document is indexed. `clauses(_:)` compiles
//  the spec as asked and, when it holds an exclusion or an OR over text,
//  adds "AND the relevant documents are evaluable" so a row is CONFIRMED,
//  never admitted because evidence is missing. `unresolvedClauses(_:)` is
//  the complement: rows that pass the positive part but whose relevant
//  documents are not evaluable — counted and shown separately.
//

import Foundation

extension SQLiteEmailStore {

    // MARK: Entry points

    /// The spec as the person asked it, confirmed only.
    static func specClauses(_ spec: SearchSpec) -> (sql: [String], binds: [QueryBind]) {
        var sql: [String] = []
        var binds: [QueryBind] = []
        for group in spec.liveGroups {
            let (groupSQL, groupBinds) = groupClause(group)
            sql.append(groupSQL)
            binds.append(contentsOf: groupBinds)
        }
        if spec.hasUncertainTextConditions {
            sql.append("NOT (\(unknownSQL(spec)))")
        }
        return (sql, binds)
    }

    /// Rows that pass the positive part but cannot be confirmed because
    /// relevant text is not evaluable yet.
    static func unresolvedClauses(_ spec: SearchSpec) -> (sql: [String], binds: [QueryBind])? {
        guard spec.hasUncertainTextConditions else { return nil }
        var sql: [String] = []
        var binds: [QueryBind] = []
        for group in spec.positivePart.liveGroups where group.kind == .all {
            let (groupSQL, groupBinds) = groupClause(group)
            sql.append(groupSQL)
            binds.append(contentsOf: groupBinds)
        }
        sql.append(unknownSQL(spec))
        return (sql, binds)
    }

    // MARK: Groups

    private static func groupClause(_ group: SearchGroup) -> (String, [QueryBind]) {
        var parts: [String] = []
        var binds: [QueryBind] = []
        for condition in group.liveConditions {
            let (sql, b) = conditionClause(condition)
            parts.append(sql); binds.append(contentsOf: b)
        }
        for attachment in group.liveAttachmentGroups {
            let (sql, b) = attachmentGroupClause(attachment)
            parts.append(sql); binds.append(contentsOf: b)
        }
        switch group.kind {
        case .all: return ("(" + parts.joined(separator: " AND ") + ")", binds)
        case .any: return ("(" + parts.joined(separator: " OR ") + ")", binds)
        case .exclude: return ("NOT (" + parts.joined(separator: " OR ") + ")", binds)
        }
    }

    /// The relevant documents are not evaluable: body (or any-text) for text
    /// conditions on the message; every attachment's text for attachment
    /// content conditions.
    private static func unknownSQL(_ spec: SearchSpec) -> String {
        var parts: [String] = []
        if spec.uncertainBodyText {
            parts.append("NOT EXISTS (SELECT 1 FROM search_docs ub WHERE ub.email_id = e.id AND ub.kind = 'body' AND ub.state IN ('complete','noText'))")
        }
        if spec.uncertainAttachmentText {
            parts.append("""
                EXISTS (SELECT 1 FROM attachments ua WHERE ua.email_id = e.id
                        AND NOT EXISTS (SELECT 1 FROM search_docs ud WHERE ud.email_id = e.id
                                        AND ud.kind IN ('attachmentText','ocrText') AND ud.ordinal = ua.position
                                        AND ud.state IN ('complete','noText')))
                """)
        }
        return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // MARK: Conditions

    private static func conditionClause(_ c: SearchCondition) -> (String, [QueryBind]) {
        let value = c.trimmedValue
        switch c.field {
        case .sender:
            if c.match == .equals {
                return ("EXISTS (SELECT 1 FROM email_participants sp WHERE sp.email_id = e.id AND sp.role = 'FROM' AND sp.normalized_address = lower(?))", [.text(value)])
            }
            return ("instr(lower(e.from_addr), lower(?)) > 0", [.text(value)])
        case .recipient, .recipientTo, .recipientCc, .recipientBcc:
            let roles: String
            switch c.field {
            case .recipientTo: roles = "'TO'"
            case .recipientCc: roles = "'CC'"
            case .recipientBcc: roles = "'BCC'"
            default: roles = "'TO','CC','BCC'"
            }
            let test = c.match == .equals ? "rp.normalized_address = lower(?)"
                : "(instr(rp.normalized_address, lower(?)) > 0 OR instr(lower(coalesce(rp.display_name, '')), lower(?)) > 0)"
            let binds: [QueryBind] = c.match == .equals ? [.text(value)] : [.text(value), .text(value)]
            return ("EXISTS (SELECT 1 FROM email_participants rp WHERE rp.email_id = e.id AND rp.role IN (\(roles)) AND \(test))", binds)
        case .subject:
            switch c.match {
            case .contains, .phrase, .equals:
                if c.match == .equals { return ("lower(e.subject) = lower(?)", [.text(value)]) }
                return ("instr(lower(e.subject), lower(?)) > 0", [.text(value)])
            case .allWords, .anyWords:
                return textClause(kinds: [.subject], match: c.match, value: value)
            }
        case .body:
            return textClause(kinds: [.body], match: c.match, value: value)
        case .anyText:
            return textClause(kinds: SearchDocKind.anyText, match: c.match, value: value)
        case .attachmentName:
            return ("EXISTS (SELECT 1 FROM attachments an WHERE an.email_id = e.id AND instr(lower(an.filename), lower(?)) > 0)", [.text(value)])
        case .hasAttachments:
            return ("e.has_attach = \(value.lowercased() == "yes" ? 1 : 0)", [])
        case .dateOnOrAfter:
            guard let day = SearchSpec.parseDay(value, timeZone: c.timeZone) else { return ("0", []) }
            return ("e.date >= ?", [.int(Int64(day.start.timeIntervalSince1970.rounded()))])
        case .dateOnOrBefore:
            guard let day = SearchSpec.parseDay(value, timeZone: c.timeZone) else { return ("0", []) }
            return ("e.date < ?", [.int(Int64(day.nextDayStart.timeIntervalSince1970.rounded()))])
        case .tag:
            return ("""
                (EXISTS (SELECT 1 FROM email_user_tags tu WHERE tu.email_id = e.id AND tu.tag = ?)
                 OR EXISTS (SELECT 1 FROM email_tags tp WHERE tp.email_id = e.id AND tp.tag = ?))
                """, [.text(value), .text(value)])
        case .folder:
            return ("EXISTS (SELECT 1 FROM email_folders cf WHERE cf.email_id = e.id AND cf.folder_id = ?)", [.int(Int64(value) ?? -1)])
        case .source:
            return ("e.source_id = ?", [.int(Int64(value) ?? -1)])
        case .messageType:
            return ("e.message_type = ?", [.text(value)])
        }
    }

    /// Text over the chunk index. FTS narrows to chunks holding the words;
    /// literal modes then verify the substring on the chunk text, so
    /// punctuation the tokeniser drops ("C++", "PO-4471") still has to be
    /// there. A phrase longer than the chunk overlap cannot be verified
    /// within one chunk and is evaluated as all-words (stated in the spec).
    private static func textClause(kinds: [SearchDocKind], match: SearchCondition.Match, value: String) -> (String, [QueryBind]) {
        let kindList = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let words = SearchTextTokens.words(in: value)
        var binds: [QueryBind] = []
        var inner: [String] = ["sc.kind IN (\(kindList))"]
        if !words.isEmpty {
            let fts: String
            switch match {
            case .anyWords: fts = words.map(SearchTextTokens.quoted).joined(separator: " OR ")
            case .contains: fts = words.map { SearchTextTokens.quoted($0) + "*" }.joined(separator: " AND ")   // word starts
            default: fts = words.map(SearchTextTokens.quoted).joined(separator: " AND ")
            }
            inner.append("search_chunks MATCH ?")
            binds.append(.text(fts))
        }
        let literal = (match == .contains || match == .phrase || match == .equals) && value.count <= SearchSpec.phraseVerificationLimit
        if literal || words.isEmpty {
            // Literal substring, verified on the chunk text (also the only
            // test when the value has no indexable word at all, e.g. "++").
            inner.append("instr(lower(sc.text), lower(?)) > 0")
            binds.append(.text(SearchTextTokens.collapsed(value)))
        }
        return ("e.id IN (SELECT sc.email_id FROM search_chunks sc WHERE \(inner.joined(separator: " AND ")))", binds)
    }

    // MARK: Attachments — one file must satisfy everything in the group

    private static func attachmentGroupClause(_ g: AttachmentConditionGroup) -> (String, [QueryBind]) {
        var tests: [String] = []
        var binds: [QueryBind] = []
        if let name = g.nameContains?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            tests.append("instr(lower(ag.filename), lower(?)) > 0")
            binds.append(.text(name))
        }
        if let type = g.type?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
            let (sql, b) = attachmentTypePredicate(type)
            tests.append(sql); binds.append(contentsOf: b)
        }
        if let content = g.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty {
            let words = SearchTextTokens.words(in: content)
            var inner: [String] = ["ac.kind IN ('attachmentText','ocrText')"]
            if !words.isEmpty {
                let fts: String
                switch g.contentMatch {
                case .anyWords: fts = words.map(SearchTextTokens.quoted).joined(separator: " OR ")
                case .contains: fts = words.map { SearchTextTokens.quoted($0) + "*" }.joined(separator: " AND ")
                default: fts = words.map(SearchTextTokens.quoted).joined(separator: " AND ")
                }
                inner.append("search_chunks MATCH ?")
                binds.append(.text(fts))
            }
            let literal = (g.contentMatch == .contains || g.contentMatch == .phrase) && content.count <= SearchSpec.phraseVerificationLimit
            if literal || words.isEmpty {
                inner.append("instr(lower(ac.text), lower(?)) > 0")
                binds.append(.text(SearchTextTokens.collapsed(content)))
            }
            // Same attachment: the chunk's (email, ordinal) is this file's (email, position).
            tests.append("(ag.email_id, ag.position) IN (SELECT ac.email_id, ac.ordinal FROM search_chunks ac WHERE \(inner.joined(separator: " AND ")))")
        }
        guard !tests.isEmpty else { return ("1", []) }
        return ("EXISTS (SELECT 1 FROM attachments ag WHERE ag.email_id = e.id AND \(tests.joined(separator: " AND ")))", binds)
    }

    /// A declared family, or a bare extension. The extension is supporting
    /// metadata: the family test also reads the declared MIME type.
    private static func attachmentTypePredicate(_ type: String) -> (String, [QueryBind]) {
        func ext(_ list: [String]) -> String {
            "(" + list.map { _ in "lower(ag.filename) LIKE ?" }.joined(separator: " OR ") + ")"
        }
        switch type.lowercased() {
        case "pdf":
            return ("(lower(ag.mime_type) LIKE '%pdf%' OR lower(ag.filename) LIKE '%.pdf')", [])
        case "images", "image":
            let exts = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]
            return ("(lower(ag.mime_type) LIKE 'image/%' OR \(ext(exts)))", exts.map { .text("%.\($0)") })
        case "office documents", "office", "documents":
            let exts = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf"]
            return ("(lower(ag.mime_type) LIKE '%officedocument%' OR lower(ag.mime_type) LIKE '%msword%' OR lower(ag.mime_type) LIKE '%ms-excel%' OR lower(ag.mime_type) LIKE '%ms-powerpoint%' OR lower(ag.mime_type) LIKE '%opendocument%' OR \(ext(exts)))",
                    exts.map { .text("%.\($0)") })
        case "archives", "archive", "zip":
            let exts = ["zip", "gz", "tgz", "7z", "rar", "tar"]
            return ("(lower(ag.mime_type) LIKE '%zip%' OR lower(ag.mime_type) LIKE '%compressed%' OR \(ext(exts)))", exts.map { .text("%.\($0)") })
        case "text":
            let exts = ["txt", "csv", "md", "log", "json", "xml", "html", "htm"]
            return ("(lower(ag.mime_type) LIKE 'text/%' OR \(ext(exts)))", exts.map { .text("%.\($0)") })
        default:
            // A bare extension such as "docx".
            let clean = type.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return ("lower(ag.filename) LIKE ?", [.text("%.\(clean)")])
        }
    }
}

/// Words as the unicode61 tokeniser sees them, and their FTS5 literal form.
enum SearchTextTokens {
    /// Runs of letters and digits; everything else separates words — the
    /// same rule as unicode61, so a MATCH never carries operator syntax.
    static func words(in value: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current); current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// A single FTS5 string token: quoted, inner quotes doubled.
    static func quoted(_ word: String) -> String {
        "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Whitespace runs collapsed to one space, for literal comparison.
    static func collapsed(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
