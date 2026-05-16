//
//  AutomationRulesEngine.swift
//  mailin
//
//  Automated email categorization and tagging rules engine
//

import Foundation
import Combine

// MARK: - Condition

enum AutomationCondition: Codable, Identifiable, Equatable {
    case senderContains(String)
    case subjectContains(String)
    case bodyContains(String)
    case domainIs(String)
    case hasAttachment
    case sentimentAbove(Double)
    case sentimentBelow(Double)
    case dateAfter(Date)
    case dateBefore(Date)
    case categoryIs(String)

    var id: String {
        switch self {
        case .senderContains(let v): return "senderContains:\(v)"
        case .subjectContains(let v): return "subjectContains:\(v)"
        case .bodyContains(let v): return "bodyContains:\(v)"
        case .domainIs(let v): return "domainIs:\(v)"
        case .hasAttachment: return "hasAttachment"
        case .sentimentAbove(let v): return "sentimentAbove:\(v)"
        case .sentimentBelow(let v): return "sentimentBelow:\(v)"
        case .dateAfter(let v): return "dateAfter:\(v.timeIntervalSince1970)"
        case .dateBefore(let v): return "dateBefore:\(v.timeIntervalSince1970)"
        case .categoryIs(let v): return "categoryIs:\(v)"
        }
    }

    var displayName: String {
        switch self {
        case .senderContains(let v): return "Sender contains \"\(v)\""
        case .subjectContains(let v): return "Subject contains \"\(v)\""
        case .bodyContains(let v): return "Body contains \"\(v)\""
        case .domainIs(let v): return "Domain is \"\(v)\""
        case .hasAttachment: return "Has attachment"
        case .sentimentAbove(let v): return "Sentiment above \(String(format: "%.1f", v))"
        case .sentimentBelow(let v): return "Sentiment below \(String(format: "%.1f", v))"
        case .dateAfter(let v): return "Date after \(AutomationCondition.dateFormatter.string(from: v))"
        case .dateBefore(let v): return "Date before \(AutomationCondition.dateFormatter.string(from: v))"
        case .categoryIs(let v): return "Category is \"\(v)\""
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// All condition type labels used for building the UI picker.
    static var allTypeLabels: [String] {
        [
            "Sender contains",
            "Subject contains",
            "Body contains",
            "Domain is",
            "Has attachment",
            "Sentiment above",
            "Sentiment below",
            "Date after",
            "Date before",
            "Category is"
        ]
    }

    /// Create a condition from a type label and a string value.
    static func from(typeLabel: String, value: String) -> AutomationCondition? {
        switch typeLabel {
        case "Sender contains":
            return value.isEmpty ? nil : .senderContains(value)
        case "Subject contains":
            return value.isEmpty ? nil : .subjectContains(value)
        case "Body contains":
            return value.isEmpty ? nil : .bodyContains(value)
        case "Domain is":
            return value.isEmpty ? nil : .domainIs(value)
        case "Has attachment":
            return .hasAttachment
        case "Sentiment above":
            guard let d = Double(value) else { return nil }
            return .sentimentAbove(d)
        case "Sentiment below":
            guard let d = Double(value) else { return nil }
            return .sentimentBelow(d)
        case "Date after":
            guard let date = ISO8601DateFormatter().date(from: value) else { return nil }
            return .dateAfter(date)
        case "Date before":
            guard let date = ISO8601DateFormatter().date(from: value) else { return nil }
            return .dateBefore(date)
        case "Category is":
            return value.isEmpty ? nil : .categoryIs(value)
        default:
            return nil
        }
    }

    /// Whether this condition type requires a text/value input.
    static func requiresValue(_ typeLabel: String) -> Bool {
        typeLabel != "Has attachment"
    }
}

// MARK: - Action

enum AutomationAction: Codable, Identifiable, Equatable {
    case addTag(String)
    case setCategory(String)
    case markPriority(String)
    case flagForReview

    var id: String {
        switch self {
        case .addTag(let v): return "addTag:\(v)"
        case .setCategory(let v): return "setCategory:\(v)"
        case .markPriority(let v): return "markPriority:\(v)"
        case .flagForReview: return "flagForReview"
        }
    }

    var displayName: String {
        switch self {
        case .addTag(let v): return "Add tag \"\(v)\""
        case .setCategory(let v): return "Set category \"\(v)\""
        case .markPriority(let v): return "Mark priority \"\(v)\""
        case .flagForReview: return "Flag for review"
        }
    }

    static var allTypeLabels: [String] {
        ["Add tag", "Set category", "Mark priority", "Flag for review"]
    }

    static func from(typeLabel: String, value: String) -> AutomationAction? {
        switch typeLabel {
        case "Add tag":
            return value.isEmpty ? nil : .addTag(value)
        case "Set category":
            return value.isEmpty ? nil : .setCategory(value)
        case "Mark priority":
            return value.isEmpty ? nil : .markPriority(value)
        case "Flag for review":
            return .flagForReview
        default:
            return nil
        }
    }

    static func requiresValue(_ typeLabel: String) -> Bool {
        typeLabel != "Flag for review"
    }
}

// MARK: - AutomationRule

struct AutomationRule: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var conditions: [AutomationCondition]
    var actions: [AutomationAction]

    init(id: UUID = UUID(), name: String, isEnabled: Bool = true, conditions: [AutomationCondition], actions: [AutomationAction]) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.actions = actions
    }
}

// MARK: - AutomationRulesEngine

@MainActor
final class AutomationRulesEngine: ObservableObject {
    @Published var rules: [AutomationRule] {
        didSet { persistRules() }
    }

    private static let storageKey = "com.mailin.automationRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([AutomationRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = Self.defaultRules
            persistRules()
        }
    }

    // MARK: - Default Rules

    static let defaultRules: [AutomationRule] = [
        AutomationRule(
            name: "Newsletters",
            isEnabled: true,
            conditions: [
                .subjectContains("newsletter"),
                .bodyContains("unsubscribe")
            ],
            actions: [
                .addTag("Newsletter"),
                .setCategory("Newsletter")
            ]
        ),
        AutomationRule(
            name: "High Priority",
            isEnabled: true,
            conditions: [
                .subjectContains("urgent"),
                .sentimentBelow(-0.4)
            ],
            actions: [
                .markPriority("High"),
                .flagForReview
            ]
        ),
        AutomationRule(
            name: "Suspicious Emails",
            isEnabled: true,
            conditions: [
                .bodyContains("verify your account"),
                .bodyContains("click here")
            ],
            actions: [
                .addTag("Suspicious"),
                .flagForReview
            ]
        )
    ]

    // MARK: - Evaluate Single Email

    /// Tests all enabled rules against an email. If ANY condition in a rule matches, the
    /// rule's actions are collected. Returns the deduplicated set of triggered actions.
    func evaluate(_ email: MBOXParser.RawEmail) -> [AutomationAction] {
        var triggered: [AutomationAction] = []
        var seenActionIDs = Set<String>()

        for rule in rules where rule.isEnabled {
            let conditionsMet = rule.conditions.contains { condition in
                evaluateCondition(condition, against: email)
            }
            if conditionsMet {
                for action in rule.actions {
                    if seenActionIDs.insert(action.id).inserted {
                        triggered.append(action)
                    }
                }
            }
        }
        return triggered
    }

    // MARK: - Bulk Evaluate

    /// Evaluate all rules against a batch of emails.
    /// Returns a mapping from email UUID to the list of actions triggered.
    func applyRules(to emails: [MBOXParser.RawEmail]) -> [UUID: [AutomationAction]] {
        var results: [UUID: [AutomationAction]] = [:]
        for email in emails {
            let actions = evaluate(email)
            if !actions.isEmpty {
                results[email.id] = actions
            }
        }
        return results
    }

    // MARK: - Condition Evaluation

    private func evaluateCondition(_ condition: AutomationCondition, against email: MBOXParser.RawEmail) -> Bool {
        switch condition {
        case .senderContains(let text):
            let from = (email.headers["From"] ?? "").lowercased()
            return from.contains(text.lowercased())

        case .subjectContains(let text):
            let subject = (email.headers["Subject"] ?? "").lowercased()
            return subject.contains(text.lowercased())

        case .bodyContains(let text):
            let body = emailBodyText(for: email).lowercased()
            return body.contains(text.lowercased())

        case .domainIs(let domain):
            return email.domains.contains { $0.lowercased() == domain.lowercased() }

        case .hasAttachment:
            return !email.attachments.isEmpty

        case .sentimentAbove(let threshold):
            let results = EmailNLPEngine.analyzeSentiment(of: [email])
            guard let result = results.first else { return false }
            return result.score > threshold

        case .sentimentBelow(let threshold):
            let results = EmailNLPEngine.analyzeSentiment(of: [email])
            guard let result = results.first else { return false }
            return result.score < threshold

        case .dateAfter(let date):
            guard let emailDate = MBOXParser.parseDate(email.headers["Date"]) else { return false }
            return emailDate > date

        case .dateBefore(let date):
            guard let emailDate = MBOXParser.parseDate(email.headers["Date"]) else { return false }
            return emailDate < date

        case .categoryIs(let category):
            let classified = EmailNLPEngine.classify(email)
            return classified.rawValue.lowercased() == category.lowercased()
        }
    }

    // MARK: - Helpers

    private func emailBodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Persistence

    private func persistRules() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Rule Management

    func addRule(_ rule: AutomationRule) {
        rules.append(rule)
    }

    func removeRule(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }

    func moveRule(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
    }

    func toggleRule(_ ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[index].isEnabled.toggle()
    }

    func updateRule(_ rule: AutomationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func resetToDefaults() {
        rules = Self.defaultRules
    }
}
