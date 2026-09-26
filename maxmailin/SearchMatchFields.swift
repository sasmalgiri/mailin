//
//  SearchMatchFields.swift
//  maxmailin
//
//  A7: the per-result "matching field" indicator. A search result row says
//  WHERE the search landed — From, To, Subject, Attachment, Body, Source,
//  Tag — instead of leaving the reader to guess why a message is in the
//  list. The terms are read through the one compiler
//  (`ArchiveQueryCompiler`), so this attributes the query the same way the
//  store executed it; nothing here re-implements search.
//
//  Two kinds of attribution:
//    • Operator fields (`from:`, `to:`, `subject:`, `filename:`, `source:`,
//      `tag:`) are guaranteed by the store's SQL for every row it returned,
//      so they are marked whenever the operator is present.
//    • Free-text terms are checked against the fields the row can see
//      (headers, attachment names, body or preview). FTS5 stems with
//      Porter, so a prefix-tolerant comparison is used; a hit that no
//      visible field explains is attributed to Body, which is the only
//      field the row never shows in full.
//

import SwiftUI

/// Where a search hit landed on a result row. Declaration order is the
/// display order.
enum SearchMatchField: String, CaseIterable, Sendable, Hashable {
    case sender
    case recipient
    case subject
    case attachment
    case body
    case source
    case tag

    var label: String {
        switch self {
        case .sender: return "From"
        case .recipient: return "To"
        case .subject: return "Subject"
        case .attachment: return "Attachment"
        case .body: return "Body"
        case .source: return "Source"
        case .tag: return "Tag"
        }
    }

    var symbol: String {
        switch self {
        case .sender: return "person"
        case .recipient: return "person.2"
        case .subject: return "textformat"
        case .attachment: return "paperclip"
        case .body: return "text.alignleft"
        case .source: return "doc"
        case .tag: return "tag"
        }
    }
}

/// The terms a search string asks about, per field. Pure value; build it once
/// per search string, not once per row.
struct SearchMatchTerms: Equatable, Sendable {
    var sender: String?
    var recipient: String?
    var subject: String?
    var attachmentName: String?
    var sourceFileName: String?
    var tag: String?
    /// Positive free-text terms (words or quoted phrases), lowercased, with
    /// FTS operators and NOT-excluded words removed. Empty for regex and
    /// proximity queries, which have no per-field reading here.
    var freeTerms: [String] = []

    init(searchText: String) {
        let compiled = ArchiveQueryCompiler.compile(searchText)
        sender = Self.normalized(compiled.sender)
        recipient = Self.normalized(compiled.recipient)
        subject = Self.normalized(compiled.subjectContains)
        attachmentName = Self.normalized(compiled.attachmentFilename)
        sourceFileName = Self.normalized(compiled.sourceFileName)
        tag = Self.normalized(compiled.userTag)
        freeTerms = Self.positiveTerms(in: compiled.text ?? "")
    }

    var isEmpty: Bool {
        sender == nil && recipient == nil && subject == nil && attachmentName == nil
            && sourceFileName == nil && tag == nil && freeTerms.isEmpty
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Words and quoted phrases the free text requires. Drops `AND`/`OR`,
    /// drops the word after `NOT`, strips grouping parentheses and the FTS
    /// prefix star. A `/regex/` or `NEAR/n` query yields nothing.
    static func positiveTerms(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count > 2 { return [] }
        if trimmed.range(of: #"\bNEAR/\d+"#, options: .regularExpression) != nil { return [] }

        var terms: [String] = []
        var skipNext = false
        for token in ArchiveQueryCompiler.tokenize(trimmed) {
            let upper = token.uppercased()
            if upper == "AND" || upper == "OR" { continue }
            if upper == "NOT" { skipNext = true; continue }
            if skipNext { skipNext = false; continue }
            var term = token.trimmingCharacters(in: CharacterSet(charactersIn: "()\"*"))
            // A quoted phrase inside parentheses: `("exact phrase")`.
            term = term.replacingOccurrences(of: "\"", with: "")
            term = term.trimmingCharacters(in: .whitespaces).lowercased()
            if !term.isEmpty, !terms.contains(term) { terms.append(term) }
        }
        return terms
    }

    // MARK: Attribution

    /// Fields that explain why a full message is in the result list.
    func matchedFields(in email: MBOXParser.RawEmail) -> [SearchMatchField] {
        let recipients = ["To", "Cc", "Bcc"].compactMap { email.headers[$0] }.joined(separator: " ")
        let body = email.isBodyCompacted ? email.bodyPreview : email.plainBody
        return matchedFields(
            from: email.headers["From"] ?? "",
            recipients: recipients,
            subject: email.headers["Subject"] ?? "",
            attachmentNames: email.attachments.map(\.filename),
            body: body
        )
    }

    /// Fields that explain why a summary row (subject / from / preview only)
    /// is in the result list.
    func matchedFields(in summary: EmailSummary) -> [SearchMatchField] {
        matchedFields(from: summary.from, recipients: "", subject: summary.subject,
                      attachmentNames: [], body: summary.bodyPreview)
    }

    func matchedFields(from: String, recipients: String, subject: String,
                       attachmentNames: [String], body: String) -> [SearchMatchField] {
        guard !isEmpty else { return [] }
        var hits = Set<SearchMatchField>()

        // Operator fields: the store's SQL guaranteed them for this row.
        if sender != nil { hits.insert(.sender) }
        if recipient != nil { hits.insert(.recipient) }
        if self.subject != nil { hits.insert(.subject) }
        if attachmentName != nil { hits.insert(.attachment) }
        if sourceFileName != nil { hits.insert(.source) }
        if tag != nil { hits.insert(.tag) }

        // Free text: verified against what the row can see.
        if !freeTerms.isEmpty {
            var explained = false
            if Self.anyTerm(freeTerms, in: from) { hits.insert(.sender); explained = true }
            if Self.anyTerm(freeTerms, in: recipients) { hits.insert(.recipient); explained = true }
            if Self.anyTerm(freeTerms, in: subject) { hits.insert(.subject); explained = true }
            if attachmentNames.contains(where: { Self.anyTerm(freeTerms, in: $0) }) {
                hits.insert(.attachment); explained = true
            }
            if Self.anyTerm(freeTerms, in: body) || !explained {
                // Either the body visibly contains a term, or nothing the row
                // shows does — and the body is the one field it never shows
                // in full (compacted rows carry only a preview).
                hits.insert(.body)
            }
        }

        return SearchMatchField.allCases.filter { hits.contains($0) }
    }

    /// Terms to highlight in the text of a given field: that field's operator
    /// value plus every positive free-text term.
    func highlightTerms(for field: SearchMatchField) -> [String] {
        var terms = freeTerms
        let operatorValue: String?
        switch field {
        case .sender: operatorValue = sender
        case .recipient: operatorValue = recipient
        case .subject: operatorValue = subject
        case .attachment: operatorValue = attachmentName
        case .body, .source, .tag: operatorValue = nil
        }
        if let operatorValue, !terms.contains(operatorValue) { terms.insert(operatorValue, at: 0) }
        return terms
    }

    // MARK: Matching

    static func anyTerm(_ terms: [String], in haystack: String) -> Bool {
        guard !haystack.isEmpty else { return false }
        let lowered = haystack.lowercased()
        return terms.contains { contains(lowered, term: $0) }
    }

    /// Literal containment, plus a Porter-tolerant word comparison for
    /// single words: `invoices` finds `invoice`, `invoic*` finds `invoicing`.
    static func contains(_ loweredHaystack: String, term: String) -> Bool {
        if loweredHaystack.contains(term) { return true }
        guard !term.contains(" ") else { return false }
        let words = loweredHaystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { word in
            word.count >= 4 && term.hasPrefix(word)
        }
    }
}

// MARK: - Row indicator

/// The compact "matched in" strip a result row shows under its subject while
/// a search is active. Renders nothing for an empty list, so it costs no
/// height when no search is running.
struct SearchMatchFieldChips: View {
    let fields: [SearchMatchField]

    var body: some View {
        if !fields.isEmpty {
            HStack(spacing: 4) {
                ForEach(fields, id: \.self) { field in
                    Label(field.label, systemImage: field.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .help("Where this search matched")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Matched in " + fields.map(\.label).joined(separator: ", "))
            .accessibilityIdentifier("search.matchedFields")
        }
    }
}
