//
//  PlainSearchTranslator.swift
//  ArchiveCore
//
//  Five jobs FIND-04 completion (plan v3 §12.3, owner 2026-11-06): the plain
//  search box runs on the same validated model as Advanced Search. The words
//  a person types become `SearchSpec` conditions over "anywhere" (subject,
//  body, names, attachment text), so the plain box gets the model's
//  three-valued answers, coverage states, evidence and — with no candidate
//  window — the whole archive.
//
//  Grammar, kept as small as the old box:
//    word word        every word (the last one as typed so far — a prefix)
//    "a phrase"       the words in order
//    a OR b           either
//    NOT word, -word  leave out
//    AND              ignored (the default)
//    in:attachments   the words must be inside one attachment's text
//

import Foundation

enum PlainSearchTranslator {
    static let attachmentsOperators: Set<String> = ["in:attachments", "in:attachment"]

    struct Term: Equatable {
        var text: String
        var isPhrase: Bool
        var negated: Bool
    }

    /// The typed text as a spec, or nil when there is nothing to search for.
    static func spec(from raw: String) -> SearchSpec? {
        var tokens = ArchiveQueryCompiler.tokenize(raw)
        let inAttachments = tokens.contains { attachmentsOperators.contains($0.lowercased()) }
        tokens.removeAll { attachmentsOperators.contains($0.lowercased()) }
        guard !tokens.isEmpty else { return nil }

        // Alternatives separated by OR; each alternative is an AND-run of terms.
        var alternatives: [[Term]] = [[]]
        var negateNext = false
        for token in tokens {
            let upper = token.uppercased()
            if upper == "AND" { continue }
            if upper == "OR" { if !(alternatives.last?.isEmpty ?? true) { alternatives.append([]) }; continue }
            if upper == "NOT" { negateNext = true; continue }
            var text = token
            var negated = negateNext
            negateNext = false
            if text.hasPrefix("-"), text.count > 1 { negated = true; text.removeFirst() }
            var isPhrase = false
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = String(text.dropFirst().dropLast()); isPhrase = true
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            alternatives[alternatives.count - 1].append(Term(text: text, isPhrase: isPhrase, negated: negated))
        }
        alternatives.removeAll(where: \.isEmpty)
        guard !alternatives.isEmpty else { return nil }

        let excluded = alternatives.flatMap { $0.filter(\.negated) }
        let positives = alternatives.map { $0.filter { !$0.negated } }.filter { !$0.isEmpty }
        var groups: [SearchGroup] = []

        if positives.count == 1 {
            groups.append(group(.all, terms: positives[0], lastIsPrefix: true, inAttachments: inAttachments))
        } else if positives.count > 1 {
            // Each OR branch becomes one "any" condition; a branch with several
            // words is folded into one all-words value so the branch stays one choice.
            var conditions: [SearchCondition] = []
            var attachmentGroups: [AttachmentConditionGroup] = []
            for branch in positives {
                let (match, value) = folded(branch)
                if inAttachments {
                    attachmentGroups.append(AttachmentConditionGroup(contentMatch: match, content: value))
                } else {
                    conditions.append(SearchCondition(.anyText, match, value))
                }
            }
            groups.append(SearchGroup(.any, conditions, attachments: attachmentGroups))
        }
        if !excluded.isEmpty {
            groups.append(group(.exclude, terms: excluded, lastIsPrefix: false, inAttachments: inAttachments))
        }
        let spec = SearchSpec(groups: groups)
        return spec.isEmpty ? nil : spec
    }

    /// One group from an AND-run: phrases stay phrases, plain words are
    /// "all words", and the last plain word is matched as typed so far.
    private static func group(_ kind: SearchGroup.Kind, terms: [Term], lastIsPrefix: Bool, inAttachments: Bool) -> SearchGroup {
        var conditions: [SearchCondition] = []
        var attachmentGroups: [AttachmentConditionGroup] = []
        var plainWords: [String] = []
        let lastPlainIndex = terms.lastIndex { !$0.isPhrase }
        for (index, term) in terms.enumerated() {
            if term.isPhrase {
                if inAttachments { attachmentGroups.append(AttachmentConditionGroup(contentMatch: .phrase, content: term.text)) }
                else { conditions.append(SearchCondition(.anyText, .phrase, term.text)) }
            } else if lastIsPrefix, index == lastPlainIndex, kind == .all {
                if inAttachments { attachmentGroups.append(AttachmentConditionGroup(contentMatch: .contains, content: term.text)) }
                else { conditions.append(SearchCondition(.anyText, .contains, term.text)) }
            } else {
                plainWords.append(term.text)
            }
        }
        if !plainWords.isEmpty {
            let value = plainWords.joined(separator: " ")
            // An exclude group leaves out any message holding any of the words.
            let match: SearchCondition.Match = kind == .exclude ? .anyWords : .allWords
            if inAttachments { attachmentGroups.append(AttachmentConditionGroup(contentMatch: match, content: value)) }
            else { conditions.append(SearchCondition(.anyText, match, value)) }
        }
        return SearchGroup(kind, conditions, attachments: attachmentGroups)
    }

    private static func folded(_ branch: [Term]) -> (SearchCondition.Match, String) {
        if branch.count == 1, branch[0].isPhrase { return (.phrase, branch[0].text) }
        return (.allWords, branch.map(\.text).joined(separator: " "))
    }

    /// `typed` merged on top of the Advanced Search spec the user applied.
    static func merge(_ typed: SearchSpec, into applied: SearchSpec?) -> SearchSpec {
        guard let applied, !applied.isEmpty else { return typed }
        return SearchSpec(groups: applied.groups + typed.groups)
    }
}

extension ArchiveBrowseState {
    /// FIND-04: the query with the typed text run on the search model (when
    /// the model is on) — the plain box and Advanced Search then share one
    /// engine, one coverage rule and one evidence path.
    func query(base: EmailQuery = .all, plainTextOnModel: Bool) -> EmailQuery {
        var q = query(base: base)
        guard plainTextOnModel, SearchChunkPolicy.isEnabled,
              let text = q.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let typed = PlainSearchTranslator.spec(from: text) else { return q }
        q.spec = PlainSearchTranslator.merge(typed, into: q.spec)
        q.text = nil
        return q
    }
}
