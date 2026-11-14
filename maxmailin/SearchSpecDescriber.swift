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
        case .account: return String(localized: "Mail account")
        case .sourceKind: return String(localized: "Came from")
        case .captureState: return String(localized: "On the server")
        }
    }

    /// V4-08: the words for the connected-mail condition values.
    static func valueName(_ field: SearchCondition.Field, _ value: String) -> String {
        switch (field, value) {
        case (.sourceKind, "file"): return String(localized: "a file import")
        case (.sourceKind, "connected"): return String(localized: "a mail account")
        case (.captureState, "onServer"): return String(localized: "still on the server")
        case (.captureState, "removedOnServer"): return String(localized: "removed from the server")
        case (.account, _): return accountNames[value.uppercased()] ?? value
        default: return value
        }
    }

    /// Display names of connected accounts by UUID, set by the builder when it
    /// loads them, so chips name the account instead of its identifier.
    nonisolated(unsafe) static var accountNames: [String: String] = [:]

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
        case .account, .sourceKind, .captureState:
            return "\(fieldName(condition.field)): \(valueName(condition.field, value))"
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
            // R01: an "any" group reads branch by branch — "(a and b) or c" —
            // and a branch-local negation reads "not …", exactly as it runs.
            let andWord = " " + String(localized: "and") + " "
            let orWord = " " + String(localized: "or") + " "
            func text(_ c: SearchCondition) -> String { (c.isNegated ? String(localized: "not") + " " : "") + chip(c) }
            func text(_ a: AttachmentConditionGroup) -> String { (a.isNegated ? String(localized: "not") + " " : "") + chip(a) }
            let list: String
            switch group.kind {
            case .all:
                list = (group.liveConditions.map(text) + group.liveAttachmentGroups.map(text)).joined(separator: andWord)
            case .any:
                list = group.branches.map { branch -> String in
                    let parts = branch.conditions.map(text) + branch.attachmentGroups.map(text)
                    return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: andWord) + ")"
                }.joined(separator: orWord)
            case .exclude:
                list = (group.liveConditions.map(chip) + group.liveAttachmentGroups.map(chip)).joined(separator: orWord)
            }
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
        return text
    }

    /// A validation problem in the person's words.
    static func problemText(_ problem: SearchSpec.Problem) -> String {
        String(localized: "Group \(problem.groupIndex + 1), condition \(problem.conditionIndex.map { $0 + 1 } ?? 0): \(problem.message)")
    }
}
