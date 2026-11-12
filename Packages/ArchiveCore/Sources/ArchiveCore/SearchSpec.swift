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
//  allWords is evaluated over the whole text of the message (every word
//  somewhere in it — audit 2026-11-06 A02: words in different chunks of one
//  long text still match). Phrases and contains are verified literally on
//  the stored text, whatever their length (R02): within one chunk, on two
//  adjacent chunks joined, or on the whole document joined from the first
//  word's chunk onward — chunks are contiguous, so the join IS the text.
//  There is no fallback from a phrase to its words.
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
        // V4-08 (plan §5.5): connected-mail scope as conditions, so OR
        // branches and exclusions combine with them like any other field.
        case account           // value = connected account UUID (mail_accounts.account_id)
        case sourceKind        // "file" (imported from a file) / "connected" (captured from an account)
        case captureState      // "onServer" / "removedOnServer" (connected copies only)
    }

    /// V4-08: the values `sourceKind` and `captureState` accept.
    static let sourceKindValues = ["file", "connected"]
    static let captureStateValues = ["onServer", "removedOnServer"]

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
    /// R01 (handoff 7481852): inside an "any" group, conditions that share a
    /// branch number are required TOGETHER (and) and the branches are the
    /// alternatives (or); nil = a branch of its own. Lets the ordinary box
    /// keep `"purchase order" urgent OR receipt` as (phrase AND word) OR word
    /// without expanding it. Ignored by all/exclude groups.
    var branch: Int? = nil
    /// R01: a branch-local "not" — the branch requires this to be absent.
    /// Optional so saved searches written before it decode.
    var negated: Bool? = nil

    init(_ field: Field, _ match: Match = .contains, _ value: String, timeZone: String? = nil,
         branch: Int? = nil, negated: Bool? = nil) {
        self.field = field
        self.match = match
        self.value = value
        self.timeZone = timeZone
        self.branch = branch
        self.negated = negated
    }

    var isNegated: Bool { negated == true }
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
    /// R01: see `SearchCondition.branch` / `negated`.
    var branch: Int? = nil
    var negated: Bool? = nil

    var isNegated: Bool { negated == true }
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
    /// R01: a branch-local negation reads text that must be absent.
    var hasNegatedText: Bool {
        liveConditions.contains { $0.isNegated && $0.readsText } || liveAttachmentGroups.contains { $0.isNegated && $0.readsText }
    }

    /// R01: the alternatives of an "any" group — conditions sharing a branch
    /// number together, every unnumbered one alone — in first-appearance order.
    struct Branch: Equatable, Sendable {
        var conditions: [SearchCondition] = []
        var attachmentGroups: [AttachmentConditionGroup] = []
    }
    var branches: [Branch] {
        var order: [Int] = []
        var byKey: [Int: Branch] = [:]
        var next = -1
        func key(_ branch: Int?) -> Int {
            if let branch { return branch }
            defer { next -= 1 }
            return next
        }
        for condition in liveConditions {
            let k = key(condition.branch)
            if byKey[k] == nil { order.append(k); byKey[k] = Branch() }
            byKey[k]!.conditions.append(condition)
        }
        for group in liveAttachmentGroups {
            let k = key(group.branch)
            if byKey[k] == nil { order.append(k); byKey[k] = Branch() }
            byKey[k]!.attachmentGroups.append(group)
        }
        return order.compactMap { byKey[$0] }
    }
}

struct SearchSpec: Codable, Equatable, Hashable, Sendable {
    static let currentVersion = 1

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
            case .any: return group.readsText && (group.branches.count > 1 || group.hasNegatedText)
            case .all: return group.hasNegatedText   // R01: a branch-local "not" is an exclusion
            }
        }
    }

    /// Which content the uncertainty is about.
    var uncertainBodyText: Bool {
        liveGroups.contains { g in (g.kind == .exclude || g.kind == .any || g.hasNegatedText) && g.liveConditions.contains { $0.readsText } }
    }
    var uncertainAttachmentText: Bool {
        liveGroups.contains { g in (g.kind == .exclude || g.kind == .any || g.hasNegatedText)
            && (g.liveAttachmentGroups.contains(where: \.readsText) || g.liveConditions.contains { $0.field == .anyText }) }
    }

    /// The spec without its exclusions — what a row has to match before an
    /// exclusion can be asked about it (used to count "unresolved" rows).
    /// R01: branch-local negations are exclusions too and are left out.
    var positivePart: SearchSpec {
        let groups = liveGroups.filter { $0.kind != .exclude }.map { group -> SearchGroup in
            var copy = group
            copy.conditions = group.liveConditions.filter { !$0.isNegated }
            copy.attachmentGroups = group.liveAttachmentGroups.filter { !$0.isNegated }
            return copy
        }
        return SearchSpec(groups: groups.filter { !$0.isEmpty })
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
                case .account:
                    if UUID(uuidString: condition.trimmedValue) == nil {
                        out.append(Problem(groupIndex: g, conditionIndex: c, message: "account must name one account"))
                    }
                case .sourceKind:
                    if !SearchCondition.sourceKindValues.contains(condition.trimmedValue) {
                        out.append(Problem(groupIndex: g, conditionIndex: c, message: "source must be file or connected"))
                    }
                case .captureState:
                    if !SearchCondition.captureStateValues.contains(condition.trimmedValue) {
                        out.append(Problem(groupIndex: g, conditionIndex: c, message: "capture state must be onServer or removedOnServer"))
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
