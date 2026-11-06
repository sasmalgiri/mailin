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

    /// R01: an "any" group is an OR over its branches, each branch an AND of
    /// its conditions; a negated condition is wrapped in NOT. No expansion —
    /// the Boolean shape is compiled as written.
    private static func groupClause(_ group: SearchGroup) -> (String, [QueryBind]) {
        var binds: [QueryBind] = []
        func clause(_ condition: SearchCondition) -> String {
            let (sql, b) = conditionClause(condition); binds.append(contentsOf: b)
            return condition.isNegated ? "NOT \(sql)" : sql
        }
        func clause(_ attachment: AttachmentConditionGroup) -> String {
            let (sql, b) = attachmentGroupClause(attachment); binds.append(contentsOf: b)
            return attachment.isNegated ? "NOT \(sql)" : sql
        }
        switch group.kind {
        case .all:
            let parts = group.liveConditions.map(clause) + group.liveAttachmentGroups.map(clause)
            return ("(" + parts.joined(separator: " AND ") + ")", binds)
        case .any:
            let alternatives = group.branches.map { branch -> String in
                let parts = branch.conditions.map(clause) + branch.attachmentGroups.map(clause)
                return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " AND ") + ")"
            }
            return ("(" + alternatives.joined(separator: " OR ") + ")", binds)
        case .exclude:
            // Inside an exclusion every condition is already a "not"; a negated
            // flag there would be a double negative and is read as plain.
            var plain: [String] = []
            for condition in group.liveConditions { let (sql, b) = conditionClause(condition); binds.append(contentsOf: b); plain.append(sql) }
            for attachment in group.liveAttachmentGroups { let (sql, b) = attachmentGroupClause(attachment); binds.append(contentsOf: b); plain.append(sql) }
            return ("NOT (" + plain.joined(separator: " OR ") + ")", binds)
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
                                        AND ud.kind IN (\(SearchDocKind.attachmentContentSQL)) AND ud.ordinal = ua.position
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

    /// Text over the chunk index. Audit 2026-11-06 A02: the words of one
    /// condition may sit in different chunks of the same text, so:
    ///  - anyWords: some chunk of these kinds holds some word.
    ///  - allWords: every word is somewhere in the message's text of these
    ///    kinds — the message is the unit (one body document; "anywhere"
    ///    means any field), each word its own FTS lookup, intersected.
    ///  - contains / phrase / equals up to the chunk overlap: FTS prefilter,
    ///    then the literal verified on one chunk's text (the overlap makes a
    ///    boundary-crossing literal whole), so punctuation the tokeniser
    ///    drops ("C++", "PO-4471") still has to be there.
    ///  - a longer literal (up to a chunk): verified on one chunk or on two
    ///    adjacent chunks joined with the overlap removed — the exact text,
    ///    not "all the words".
    ///  - a literal longer than a chunk: all its words in the message (the
    ///    describer says so; `SearchSpec.phraseWholeTextLimit`).
    private static func textClause(kinds: [SearchDocKind], match: SearchCondition.Match, value: String) -> (String, [QueryBind]) {
        let kindList = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let words = SearchTextTokens.words(in: value)
        let prefix = match == .contains
        if words.isEmpty {
            // No indexable word at all ("++"): the literal alone, on any chunk of these kinds.
            return ("e.id IN (SELECT sc.email_id FROM search_chunks sc WHERE sc.kind IN (\(kindList)) AND instr(lower(sc.text), lower(?)) > 0)",
                    [.text(SearchTextTokens.collapsed(value))])
        }
        switch match {
        case .anyWords:
            return ("e.id IN (SELECT sc.email_id FROM search_chunks sc WHERE sc.kind IN (\(kindList)) AND search_chunks MATCH ?)",
                    [.text(words.map(SearchTextTokens.quoted).joined(separator: " OR "))])
        case .allWords:
            // Each word somewhere in the message's text of these kinds.
            var parts: [String] = []
            var binds: [QueryBind] = []
            for word in words {
                parts.append("e.id IN (SELECT sc.email_id FROM search_chunks sc WHERE sc.kind IN (\(kindList)) AND search_chunks MATCH ?)")
                binds.append(.text(SearchTextTokens.quoted(word)))
            }
            return ("(" + parts.joined(separator: " AND ") + ")", binds)
        case .contains, .phrase, .equals:
            return literalClause(kindList: kindList, words: words, prefix: prefix, literal: SearchTextTokens.collapsed(value),
                                 sameDocument: "c1.email_id = e.id", mayExceedChunk: value.count > SearchChunker.chunkCharacters)
        }
    }

    /// R02: a literal verified on the stored text, whatever its length.
    /// Chunks are contiguous, so the text IS the chunks joined in order:
    ///  - within one chunk (FTS prefilter: every word in that chunk);
    ///  - across two adjacent chunks joined (first word in the first, last
    ///    word in the second);
    ///  - longer than a chunk: the document from the first word's chunk
    ///    onward, joined in chunk order (SQLite ≥ 3.44 orders inside
    ///    group_concat) — exact, and only compiled when the literal is that long.
    /// The table-valued form `search_chunks(?)` carries the FTS query;
    /// `sameDocument` correlates `c1` with the outer row. Nothing ever falls
    /// back to "all the words".
    static func literalClause(kindList: String, words: [String], prefix: Bool, literal: String,
                              sameDocument: String, mayExceedChunk: Bool) -> (String, [QueryBind]) {
        func token(_ word: String) -> String { SearchTextTokens.quoted(word) + (prefix ? "*" : "") }
        let all = words.map(token).joined(separator: " AND ")
        let first = token(words[0]), last = token(words[words.count - 1])
        let single = "EXISTS (SELECT 1 FROM search_chunks(?) c1 WHERE \(sameDocument) AND c1.kind IN (\(kindList))"
            + " AND instr(lower(c1.text), lower(?)) > 0)"
        let pair = "EXISTS (SELECT 1 FROM search_chunks(?) c1, search_chunks(?) c2 WHERE \(sameDocument) AND c1.kind IN (\(kindList))"
            + " AND c2.email_id = c1.email_id AND c2.kind = c1.kind AND c2.ordinal = c1.ordinal AND c2.chunk = c1.chunk + 1"
            + " AND instr(lower(c1.text || c2.text), lower(?)) > 0)"
        var parts = [single, pair]
        var binds: [QueryBind] = [.text(all), .text(literal), .text(first), .text(last), .text(literal)]
        if mayExceedChunk {
            parts.append("EXISTS (SELECT 1 FROM search_chunks(?) c1 WHERE \(sameDocument) AND c1.kind IN (\(kindList))"
                + " AND instr(lower((SELECT group_concat(c.text, '' ORDER BY c.chunk) FROM search_chunks c"
                + " WHERE c.email_id = c1.email_id AND c.kind = c1.kind AND c.ordinal = c1.ordinal AND c.chunk >= c1.chunk)), lower(?)) > 0)")
            binds.append(contentsOf: [.text(first), .text(literal)])
        }
        return ("(" + parts.joined(separator: " OR ") + ")", binds)
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
            // Same attachment throughout: a chunk's (email, ordinal) is this file's (email, position).
            // Audit A02: the same four forms as `textClause`, correlated on the file.
            let words = SearchTextTokens.words(in: content)
            let kindList = SearchDocKind.attachmentContentSQL
            let prefix = g.contentMatch == .contains
            if words.isEmpty {
                tests.append("(ag.email_id, ag.position) IN (SELECT ac.email_id, ac.ordinal FROM search_chunks ac WHERE ac.kind IN (\(kindList)) AND instr(lower(ac.text), lower(?)) > 0)")
                binds.append(.text(SearchTextTokens.collapsed(content)))
            } else {
                switch g.contentMatch {
                case .anyWords:
                    tests.append("(ag.email_id, ag.position) IN (SELECT ac.email_id, ac.ordinal FROM search_chunks ac WHERE ac.kind IN (\(kindList)) AND search_chunks MATCH ?)")
                    binds.append(.text(words.map(SearchTextTokens.quoted).joined(separator: " OR ")))
                case .allWords:
                    for word in words {
                        tests.append("(ag.email_id, ag.position) IN (SELECT ac.email_id, ac.ordinal FROM search_chunks ac WHERE ac.kind IN (\(kindList)) AND search_chunks MATCH ?)")
                        binds.append(.text(SearchTextTokens.quoted(word)))
                    }
                case .contains, .phrase, .equals:
                    let (sql, b) = literalClause(kindList: kindList, words: words, prefix: prefix, literal: SearchTextTokens.collapsed(content),
                                                 sameDocument: "c1.email_id = ag.email_id AND c1.ordinal = ag.position",
                                                 mayExceedChunk: content.count > SearchChunker.chunkCharacters)
                    tests.append(sql); binds.append(contentsOf: b)
                }
            }
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
