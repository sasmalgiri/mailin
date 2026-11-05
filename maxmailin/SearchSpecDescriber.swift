@testable import ArchiveCore
//
//  SearchSpecDescriber.swift
//  maxmailin
//
//  Five jobs FIND-04 (plan §5.3.3): the words for a `SearchSpec` — the
//  plain-language summary under the builder, the applied-filter chips, and
//  the group labels — all read from the same model that runs, so what the
//  person sees is what executes. Match modes are named because they differ
//  (see SearchSpec.swift).
//

import Foundation

enum SearchSpecDescriber {

    static func fieldName(_ field: SearchCondition.Field) -> String {
        switch field {
        case .sender: return String(localized: "Sender")
        case .recipient: return String(localized: "Any recipient")
        case .recipientTo: return String(localized: "To")
        case .recipientCc: return String(localized: "Cc")
        case .recipientBcc: return String(localized: "Bcc")
        case .subject: return String(localized: "Subject")
        case .body: return String(localized: "Message body")
        case .anyText: return String(localized: "Anywhere (subject, body, names, attachment text)")
        case .attachmentName: return String(localized: "Attachment name")
        case .hasAttachments: return String(localized: "Has attachments")
        case .dateOnOrAfter: return String(localized: "Date on or after")
        case .dateOnOrBefore: return String(localized: "Date on or before")
        case .tag: return String(localized: "Tag or label")
        case .folder: return String(localized: "Folder")
        case .source: return String(localized: "Source")
        case .messageType: return String(localized: "Type")
        }
    }

    static func matchName(_ match: SearchCondition.Match) -> String {
        switch match {
        case .contains: return String(localized: "starts like")
        case .phrase: return String(localized: "has the phrase")
        case .allWords: return String(localized: "has all the words")
        case .anyWords: return String(localized: "has any of the words")
        case .equals: return String(localized: "is")
        }
    }

    static func groupLabel(_ kind: SearchGroup.Kind) -> String {
        switch kind {
        case .all: return String(localized: "All of")
        case .any: return String(localized: "Any of")
        case .exclude: return String(localized: "Exclude")
        }
    }

    /// One chip's text.
    static func chip(_ condition: SearchCondition) -> String {
        let value = condition.trimmedValue
        switch condition.field {
        case .hasAttachments:
            return value.lowercased() == "yes" ? String(localized: "Has attachments") : String(localized: "No attachments")
        case .dateOnOrAfter, .dateOnOrBefore:
            let zone = condition.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            return "\(fieldName(condition.field)) \(value) (\(zone.identifier))"
        case .subject where condition.match == .contains, .sender where condition.match == .contains,
             .attachmentName, .tag, .folder, .source, .messageType:
            return "\(fieldName(condition.field)): \(value)"
        default:
            return "\(fieldName(condition.field)) \(matchName(condition.match)) “\(value)”"
        }
    }

    static func chip(_ group: AttachmentConditionGroup) -> String {
        var parts: [String] = []
        if let type = group.type?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
            parts.append(String(localized: "type \(type)"))
        }
        if let name = group.nameContains?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            parts.append(String(localized: "name has “\(name)”"))
        }
        if let content = group.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty {
            parts.append("\(String(localized: "text")) \(matchName(group.contentMatch)) “\(content)”")
        }
        return String(localized: "One attachment: \(parts.joined(separator: ", "))")
    }

    /// The whole spec in one or two sentences, in the order it runs.
    static func summary(_ spec: SearchSpec) -> String {
        let groups = spec.liveGroups
        guard !groups.isEmpty else { return String(localized: "No conditions — the list shows the selected scope.") }
        var sentences: [String] = []
        for group in groups {
            let items = group.liveConditions.map(chip) + group.liveAttachmentGroups.map(chip)
            let joiner: String
            switch group.kind {
            case .all: joiner = " " + String(localized: "and") + " "
            case .any: joiner = " " + String(localized: "or") + " "
            case .exclude: joiner = " " + String(localized: "or") + " "
            }
            let list = items.joined(separator: joiner)
            switch group.kind {
            case .all: sentences.append(String(localized: "Messages where \(list)."))
            case .any: sentences.append(String(localized: "Messages where \(list)."))
            case .exclude: sentences.append(String(localized: "Leaving out messages where \(list)."))
            }
        }
        var text = sentences.joined(separator: " ")
        if spec.hasUncertainTextConditions {
            text += " " + String(localized: "Messages whose text is not indexed yet are counted apart as “may still match”.")
        }
        if groups.contains(where: { g in g.liveConditions.contains { $0.match == .phrase && $0.trimmedValue.count > SearchSpec.phraseVerificationLimit } }) {
            text += " " + String(localized: "A phrase longer than \(SearchSpec.phraseVerificationLimit) characters is matched as all its words in the same text.")
        }
        return text
    }

    /// A validation problem in the person's words.
    static func problemText(_ problem: SearchSpec.Problem) -> String {
        String(localized: "Group \(problem.groupIndex + 1), condition \(problem.conditionIndex.map { $0 + 1 } ?? 0): \(problem.message)")
    }
}
