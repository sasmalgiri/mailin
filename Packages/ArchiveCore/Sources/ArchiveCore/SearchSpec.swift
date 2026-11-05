//
//  SearchSpec.swift
//  ArchiveCore
//
//  Five jobs FIND-04 (plan §5.3.4): ONE typed, versioned search model that
//  drives the builder, the applied chips, the plain-language summary, the
//  SQL, the counts, the coverage question and the export selection. The
//  builder never concatenates a display string and hopes it reparses.
//
//  Shape: groups combined with AND. A group is "all of", "any of" or
//  "exclude" (none of) its conditions. An attachment group inside a group
//  names conditions ONE attachment must satisfy together (type AND name AND
//  content of the same file). Empty groups and empty conditions have no
//  effect. Scope (source, folder, trash, entitlement) lives OUTSIDE the
//  spec, on `EmailQuery`, so no OR branch or exclusion can escape it.
//
//  Text semantics are explicit per condition (`Match`), and each is stated
//  on the summary because they differ:
//    contains  — the typed text, with the same word starts, in order; a
//                literal case-insensitive test on the stored text after an
//                FTS prefilter on word prefixes. "C++" needs the "++";
//                "ephyr" inside "zephyr" is NOT found (word starts only).
//    phrase    — the words in order, whole, literal.
//    allWords / anyWords — whole tokens on the unicode61 tokeniser,
//                diacritics folded, no stemming: a plural does not find a
//                singular.
//  Phrases and contains are verified within one chunk; chunks overlap by
//  `SearchChunker.overlapCharacters`, so a phrase up to that length is found
//  even where it crosses a chunk boundary; a longer phrase is evaluated as
//  "all words in the same document" and the summary says so
//  (`SearchSpec.phraseVerificationLimit`).
//

import Foundation

struct SearchCondition: Codable, Equatable, Hashable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case sender            // From address or name
        case recipient         // To, Cc or Bcc
        case recipientTo
        case recipientCc
        case recipientBcc
        case subject
        case body
        case anyText           // subject, body, names and attachment text together
        case attachmentName
        case hasAttachments    // value "yes" / "no"
        case dateOnOrAfter     // value "yyyy-MM-dd" in `timeZone`
        case dateOnOrBefore    // value "yyyy-MM-dd" in `timeZone` (inclusive)
        case tag               // exact label or user tag
        case folder            // value = folders.folder_id
        case source            // value = sources.source_id
        case messageType       // "sent" / "received"
    }

    enum Match: String, Codable, CaseIterable, Sendable {
        /// Literal, case-insensitive substring.
        case contains
        /// Literal, case-insensitive substring of the words in order.
        case phrase
        /// Every word present as a whole token (any order).
        case allWords
        /// At least one word present as a whole token.
        case anyWords
        /// Exact value (address, type, id, yes/no, date).
        case equals
    }

    var field: Field
    var match: Match = .contains
    var value: String
    /// For date fields: the identifier of the zone the day is shown in.
    var timeZone: String? = nil

    init(_ field: Field, _ match: Match = .contains, _ value: String, timeZone: String? = nil) {
        self.field = field
        self.match = match
        self.value = value
        self.timeZone = timeZone
    }

    var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmedValue.isEmpty }

    /// Conditions that read indexed text and therefore depend on coverage.
    var readsText: Bool {
        switch field {
        case .body, .anyText: return true
        case .subject: return match != .contains && match != .equals
        default: return false
        }
    }
}

/// What one attachment must satisfy, all at once.
struct AttachmentConditionGroup: Codable, Equatable, Hashable, Sendable {
    /// Original filename contains (case-insensitive).
    var nameContains: String? = nil
    /// A declared family ("PDF", "Images", "Office documents", "Text",
    /// "Archives") or a lower-cased extension ("docx").
    var type: String? = nil
    /// Extracted or recognised text of THIS attachment.
    var contentMatch: SearchCondition.Match = .phrase
    var content: String? = nil

    var isEmpty: Bool {
        (nameContains?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            && (type?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            && (content?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
    var readsText: Bool { !(content?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
}

struct SearchGroup: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case all, any, exclude
    }
    var kind: Kind
    var conditions: [SearchCondition] = []
    var attachmentGroups: [AttachmentConditionGroup] = []

    init(_ kind: Kind, _ conditions: [SearchCondition] = [], attachments: [AttachmentConditionGroup] = []) {
        self.kind = kind
        self.conditions = conditions
        self.attachmentGroups = attachments
    }

    var liveConditions: [SearchCondition] { conditions.filter { !$0.isEmpty } }
    var liveAttachmentGroups: [AttachmentConditionGroup] { attachmentGroups.filter { !$0.isEmpty } }
    var isEmpty: Bool { liveConditions.isEmpty && liveAttachmentGroups.isEmpty }
    var readsText: Bool { liveConditions.contains(where: \.readsText) || liveAttachmentGroups.contains(where: \.readsText) }
}

struct SearchSpec: Codable, Equatable, Hashable, Sendable {
    static let currentVersion = 1
    /// Phrases up to this many characters are verified across chunk
    /// boundaries (the chunk overlap); longer ones fall back to all-words.
    static var phraseVerificationLimit: Int { SearchChunker.overlapCharacters }

    var version: Int = SearchSpec.currentVersion
    var groups: [SearchGroup] = []

    init(groups: [SearchGroup] = []) { self.groups = groups }

    var liveGroups: [SearchGroup] { groups.filter { !$0.isEmpty } }
    var isEmpty: Bool { liveGroups.isEmpty }

    /// A text condition whose absence cannot be proven on unindexed content:
    /// anything inside an exclude group, or inside an any-group next to
    /// other branches (an unknown branch leaves the OR unknown).
    var hasUncertainTextConditions: Bool {
        liveGroups.contains { group in
            switch group.kind {
            case .exclude: return group.readsText
            case .any: return group.readsText && (group.liveConditions.count + group.liveAttachmentGroups.count) > 1
            case .all: return false
            }
        }
    }

    /// Which content the uncertainty is about.
    var uncertainBodyText: Bool {
        liveGroups.contains { g in (g.kind == .exclude || g.kind == .any) && g.liveConditions.contains { $0.readsText } }
    }
    var uncertainAttachmentText: Bool {
        liveGroups.contains { g in (g.kind == .exclude || g.kind == .any)
            && (g.liveAttachmentGroups.contains(where: \.readsText) || g.liveConditions.contains { $0.field == .anyText }) }
    }

    /// The spec without its exclusions — what a row has to match before an
    /// exclusion can be asked about it (used to count "unresolved" rows).
    var positivePart: SearchSpec {
        SearchSpec(groups: liveGroups.filter { $0.kind != .exclude })
    }

    // MARK: Editing (the chips remove exactly one thing)

    /// Without the condition at `condition` of group `group`. Empty groups stay
    /// (they have no effect) so indices elsewhere do not move.
    func removingCondition(group: Int, condition: Int) -> SearchSpec {
        var copy = self
        guard groups.indices.contains(group), groups[group].conditions.indices.contains(condition) else { return copy }
        copy.groups[group].conditions.remove(at: condition)
        return copy
    }

    func removingAttachmentGroup(group: Int, attachment: Int) -> SearchSpec {
        var copy = self
        guard groups.indices.contains(group), groups[group].attachmentGroups.indices.contains(attachment) else { return copy }
        copy.groups[group].attachmentGroups.remove(at: attachment)
        return copy
    }

    /// Groups with at least one live condition, with their original index.
    var indexedLiveGroups: [(index: Int, group: SearchGroup)] {
        groups.enumerated().filter { !$0.element.isEmpty }.map { (index: $0.offset, group: $0.element) }
    }

    // MARK: Validation (plan rule 2: reject inline, never run a different query)

    struct Problem: Equatable, Sendable {
        let groupIndex: Int
        let conditionIndex: Int?
        let message: String
    }

    static let dateFormat = "yyyy-MM-dd"

    static func parseDay(_ value: String, timeZone: String?) -> (start: Date, nextDayStart: Date)? {
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = dateFormat
        guard let start = formatter.date(from: value.trimmingCharacters(in: .whitespaces)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, next)
    }

    func problems() -> [Problem] {
        var out: [Problem] = []
        for (g, group) in groups.enumerated() {
            for (c, condition) in group.conditions.enumerated() where !condition.isEmpty {
                switch condition.field {
                case .dateOnOrAfter, .dateOnOrBefore:
                    if Self.parseDay(condition.value, timeZone: condition.timeZone) == nil {
                        out.append(Problem(groupIndex: g, conditionIndex: c, message: "not a date (yyyy-MM-dd): \(condition.value)"))
                    }
                case .hasAttachments:
                    if !["yes", "no"].contains(condition.trimmedValue.lowercased()) {
                        out.append(Problem(groupIndex: g, conditionIndex: c, message: "has attachments must be yes or no"))
                    }
                case .folder, .source:
                    if Int64(condition.trimmedValue) == nil {
                        out.append(Problem(groupIndex: g, conditionIndex: c, message: "\(condition.field.rawValue) must name one item"))
                    }
                default:
                    break
                }
            }
        }
        return out
    }

    var isValid: Bool { problems().isEmpty }
}
