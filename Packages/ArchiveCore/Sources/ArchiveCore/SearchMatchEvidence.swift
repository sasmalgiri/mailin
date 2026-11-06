//
//  SearchMatchEvidence.swift
//  ArchiveCore
//
//  Five jobs FIND-05 (plan §5.3.6): "Why is this here?" answered from what
//  actually matched. For one result row and the applied search, the chunk
//  index is asked which document held the words — subject, sender,
//  recipients, body, an attachment's name or text (with its ordinal, so two
//  files with the same name stay apart, and the nearest "[Sheet: …]" /
//  "[Slide N]" label as location) — and a short excerpt is cut from the
//  chunk text with the matched words marked up by position. Metadata
//  conditions (sender, date, has attachments…) are reported as such, with
//  no text excerpt invented. When a text condition has no evidence (the
//  text is not indexed yet) the answer is "evidence unavailable", never a
//  guessed Body.
//
//  Excerpts are plain text cut from stored text; nothing here renders
//  HTML. The marks are offsets the UI turns into bold.
//

import Foundation
import SQLite3

struct MatchEvidence: Sendable, Equatable {
    enum Location: Sendable, Equatable {
        case subject, sender, recipients, body
        case attachmentName
        case attachmentText(ordinal: Int, filename: String, ocr: Bool, context: String?)
        /// TYPE-05: words recognised in an audio or video attachment.
        case speech(ordinal: Int, filename: String, context: String?)
        /// A condition on metadata (dates, attachments yes/no, tags, folders…) that the row passed.
        case metadata
        /// A text condition whose evidence could not be found in the index.
        case unavailable
    }

    struct Excerpt: Sendable, Equatable {
        let text: String
        /// Ranges in `text` (as UTF-16 offsets) of the matched words/phrase.
        let marks: [Range<Int>]
    }

    let location: Location
    /// The condition this evidence answers, in the compiler's own terms
    /// (field + mode + value), for the chip's tooltip.
    let condition: String
    let excerpt: Excerpt?
}

extension SQLiteEmailStore {

    /// Evidence for one row under `spec`; free text (the search box) is
    /// treated as "all the words, anywhere". Empty when neither is given.
    func matchEvidence(emailID: UUID, spec: SearchSpec?, freeText: String?) throws -> [MatchEvidence] {
        var out: [MatchEvidence] = []
        if let spec {
            for group in spec.liveGroups where group.kind != .exclude {
                for condition in group.liveConditions {
                    out.append(contentsOf: try evidence(emailID: emailID, condition: condition))
                }
                for attachment in group.liveAttachmentGroups {
                    out.append(contentsOf: try evidence(emailID: emailID, attachment: attachment))
                }
            }
        }
        if let freeText = freeText?.trimmingCharacters(in: .whitespacesAndNewlines), !freeText.isEmpty {
            let words = SearchTextTokens.words(in: freeText)
            if !words.isEmpty {
                let hits = try textHits(emailID: emailID, kinds: SearchDocKind.anyText, words: words,
                                        literal: nil, prefix: true, limit: 3)
                if hits.isEmpty {
                    out.append(MatchEvidence(location: .unavailable, condition: freeText, excerpt: nil))
                } else {
                    out.append(contentsOf: hits.map { MatchEvidence(location: $0.location, condition: freeText, excerpt: $0.excerpt) })
                }
            }
        }
        // One chip per place: the same location found by two conditions reads once.
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.location)|\($0.condition)").inserted }
    }

    // MARK: Conditions

    private func evidence(emailID: UUID, condition c: SearchCondition) throws -> [MatchEvidence] {
        let label = "\(c.field.rawValue) \(c.match.rawValue) “\(c.trimmedValue)”"
        switch c.field {
        case .body, .anyText, .subject:
            let kinds: [SearchDocKind]
            switch c.field {
            case .body: kinds = [.body]
            case .subject: kinds = [.subject]
            default: kinds = SearchDocKind.anyText
            }
            // Subject contains/equals is a metadata test in SQL; still show the subject as the place.
            if c.field == .subject, c.match == .contains || c.match == .equals {
                return [MatchEvidence(location: .subject, condition: label, excerpt: nil)]
            }
            let words = SearchTextTokens.words(in: c.trimmedValue)
            let literal = (c.match == .contains || c.match == .phrase) && c.trimmedValue.count <= SearchSpec.phraseVerificationLimit
                ? SearchTextTokens.collapsed(c.trimmedValue) : nil
            let hits = try textHits(emailID: emailID, kinds: kinds, words: words, literal: literal,
                                    prefix: c.match == .contains, anyWord: c.match == .anyWords, limit: 2)
            if hits.isEmpty { return [MatchEvidence(location: .unavailable, condition: label, excerpt: nil)] }
            return hits.map { MatchEvidence(location: $0.location, condition: label, excerpt: $0.excerpt) }
        case .sender:
            return [MatchEvidence(location: .sender, condition: label, excerpt: nil)]
        case .recipient, .recipientTo, .recipientCc, .recipientBcc:
            return [MatchEvidence(location: .recipients, condition: label, excerpt: nil)]
        case .attachmentName:
            return [MatchEvidence(location: .attachmentName, condition: label, excerpt: nil)]
        default:
            return [MatchEvidence(location: .metadata, condition: label, excerpt: nil)]
        }
    }

    private func evidence(emailID: UUID, attachment g: AttachmentConditionGroup) throws -> [MatchEvidence] {
        let label = "attachment " + [g.type.map { "type \($0)" }, g.nameContains.map { "name “\($0)”" },
                                     g.content.map { "\(g.contentMatch.rawValue) “\($0)”" }].compactMap { $0 }.joined(separator: ", ")
        guard let content = g.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
            return [MatchEvidence(location: .attachmentName, condition: label, excerpt: nil)]
        }
        let words = SearchTextTokens.words(in: content)
        let literal = (g.contentMatch == .contains || g.contentMatch == .phrase) && content.count <= SearchSpec.phraseVerificationLimit
            ? SearchTextTokens.collapsed(content) : nil
        let hits = try textHits(emailID: emailID, kinds: SearchDocKind.attachmentContent, words: words, literal: literal,
                                prefix: g.contentMatch == .contains, anyWord: g.contentMatch == .anyWords, limit: 3)
        // Only files that also satisfy the group's name/type belong to this evidence.
        let qualifying = hits.filter { hit in
            guard case .attachmentText(_, let filename, _, _) = hit.location else { return false }
            if let name = g.nameContains?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
               !filename.lowercased().contains(name.lowercased()) { return false }
            return true
        }
        if qualifying.isEmpty { return [MatchEvidence(location: .unavailable, condition: label, excerpt: nil)] }
        return qualifying.map { MatchEvidence(location: $0.location, condition: label, excerpt: $0.excerpt) }
    }

    // MARK: Chunk lookup

    private struct Hit { let location: MatchEvidence.Location; let excerpt: MatchEvidence.Excerpt }

    /// Chunks of this email, in `kinds`, holding the words (FTS) and — for
    /// literal modes — the exact text; one hit per document, with an
    /// excerpt around the first matched word.
    private func textHits(emailID: UUID, kinds: [SearchDocKind], words: [String], literal: String?,
                          prefix: Bool, anyWord: Bool = false, limit: Int) throws -> [Hit] {
        let db = try ensureDB()
        var sql = """
            SELECT sc.kind, sc.ordinal, sc.text FROM search_chunks sc
            WHERE sc.email_id = ? AND sc.kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")))
            """
        var binds: [QueryBind] = [.text(emailID.uuidString)]
        if !words.isEmpty {
            let tokens = words.map { SearchTextTokens.quoted($0) + (prefix ? "*" : "") }
            sql += " AND search_chunks MATCH ?"
            binds.append(.text(tokens.joined(separator: anyWord ? " OR " : " AND ")))
        }
        if let literal {
            sql += " AND instr(lower(sc.text), lower(?)) > 0"
            binds.append(.text(literal))
        }
        sql += " ORDER BY sc.kind, sc.ordinal, sc.chunk LIMIT 24;"
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        _ = bindQueryValues(stmt, binds, startingAt: 1)
        var hits: [Hit] = []
        var seenDocs = Set<String>()
        let filenames = (try? attachmentMetadata(forEmailID: emailID))?.map(\.filename) ?? []
        while try stepRow(stmt, db), hits.count < limit {
            guard let kind = SearchDocKind(rawValue: columnText(stmt, 0)) else { continue }
            let ordinal = Int(sqlite3_column_int64(stmt, 1))
            let key = "\(kind.rawValue)#\(ordinal)"
            guard seenDocs.insert(key).inserted else { continue }
            let text = columnText(stmt, 2)
            let excerpt = Self.excerpt(from: text, words: words, literal: literal)
            let location: MatchEvidence.Location
            switch kind {
            case .subject: location = .subject
            case .sender: location = .sender
            case .recipients: location = .recipients
            case .body: location = .body
            case .attachmentName: location = .attachmentName
            case .attachmentText, .ocrText:
                let filename = filenames.indices.contains(ordinal) ? filenames[ordinal] : ""
                location = .attachmentText(ordinal: ordinal, filename: filename, ocr: kind == .ocrText,
                                           context: Self.nearestLabel(in: text, before: excerpt.marks.first?.lowerBound))
            case .speechText:
                let filename = filenames.indices.contains(ordinal) ? filenames[ordinal] : ""
                location = .speech(ordinal: ordinal, filename: filename,
                                   context: Self.nearestLabel(in: text, before: excerpt.marks.first?.lowerBound))
            }
            hits.append(Hit(location: location, excerpt: excerpt))
        }
        return hits
    }

    /// ~160 characters around the first match, with the matched words
    /// marked by UTF-16 offsets; the first match is the literal when there
    /// is one, else the first of the words (case-insensitive).
    static func excerpt(from text: String, words: [String], literal: String?, radius: Int = 80) -> MatchEvidence.Excerpt {
        let ns = text as NSString
        var ranges: [NSRange] = []
        if let literal, !literal.isEmpty {
            let r = ns.range(of: literal, options: [.caseInsensitive, .diacriticInsensitive])
            if r.location != NSNotFound { ranges.append(r) }
        }
        if ranges.isEmpty {
            for word in words {
                let r = ns.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
                if r.location != NSNotFound { ranges.append(r) }
            }
        }
        let anchor = ranges.map(\.location).min() ?? 0
        let start = max(0, anchor - radius)
        let end = min(ns.length, (ranges.map { $0.location + $0.length }.max() ?? anchor) + radius)
        var window = ns.substring(with: NSRange(location: start, length: end - start))
        window = window.replacingOccurrences(of: "\n", with: " ")
        if start > 0 { window = "…" + window }
        if end < ns.length { window += "…" }
        let shift = (start > 0 ? 1 : 0) - start
        let marks = ranges.compactMap { r -> Range<Int>? in
            let lo = r.location + shift, hi = r.location + r.length + shift
            return lo >= 0 && hi <= (window as NSString).length ? lo..<hi : nil
        }
        return MatchEvidence.Excerpt(text: window, marks: marks)
    }

    /// The last "[…]" component label before the match, when the text has one
    /// ("[Sheet: Q3]", "[Slide 2]", "[Header]").
    static func nearestLabel(in text: String, before offset: Int?) -> String? {
        let ns = text as NSString
        let limit = offset.map { min(max($0, 0), ns.length) } ?? ns.length
        let head = ns.substring(to: limit)
        guard let open = head.range(of: "[", options: .backwards) else { return nil }
        let tail = head[open.lowerBound...]
        guard let close = tail.firstIndex(of: "]") else { return nil }
        let label = String(tail[tail.index(after: open.lowerBound)..<close])
        return label.isEmpty || label.count > 60 ? nil : label
    }
}
