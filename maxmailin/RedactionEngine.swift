//
//  RedactionEngine.swift
//  mailin
//
//  PII auto-redaction engine for privacy-safe exports.
//  Applies configurable regex-based redaction rules to email content.
//

import SwiftUI
import os.log

private let redactionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Redaction")

// MARK: - RedactionEngine

struct RedactionEngine {

    // MARK: - Rule Definition

    struct RedactionRule: Identifiable, Codable, Equatable, @unchecked Sendable {
        let id: UUID
        let type: PIICategory
        let pattern: String
        let replacement: String
        var isEnabled: Bool

        init(id: UUID = UUID(), type: PIICategory, pattern: String, replacement: String, isEnabled: Bool = true) {
            self.id = id
            self.type = type
            self.pattern = pattern
            self.replacement = replacement
            self.isEnabled = isEnabled
        }
    }

    enum PIICategory: String, Codable, CaseIterable, Identifiable {
        case ssn = "SSN"
        case creditCard = "Credit Card"
        case phoneNumber = "Phone Number"
        case emailAddress = "Email Address"
        case dateOfBirth = "Date of Birth"
        case person = "Person"
        case custom = "Custom"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .ssn: return "number.circle"
            case .creditCard: return "creditcard"
            case .phoneNumber: return "phone"
            case .emailAddress: return "envelope"
            case .dateOfBirth: return "calendar"
            case .person: return "person.crop.circle.badge.minus"
            case .custom: return "gearshape"
            }
        }
    }

    // MARK: - Redact by Person

    static func personRedactionRules(name: String, email: String? = nil, replacement: String = "[REDACTED PERSON]") -> [RedactionRule] {
        var rules: [RedactionRule] = []
        let nameTrimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nameTrimmed.isEmpty else { return rules }

        let escaped = NSRegularExpression.escapedPattern(for: nameTrimmed)
        rules.append(RedactionRule(type: .person, pattern: "\\b\(escaped)\\b", replacement: replacement, isEnabled: true))

        let parts = nameTrimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 {
            let firstName = NSRegularExpression.escapedPattern(for: parts[0])
            guard let lastPart = parts.last else { return rules }
            let lastName = NSRegularExpression.escapedPattern(for: lastPart)
            rules.append(RedactionRule(type: .person, pattern: "\\b\(firstName)\\s+\(lastName)\\b", replacement: replacement, isEnabled: true))
            rules.append(RedactionRule(type: .person, pattern: "\\b\(lastName),\\s*\(firstName)\\b", replacement: replacement, isEnabled: true))
            if parts[0].count > 1 {
                let initial = String(parts[0].prefix(1))
                rules.append(RedactionRule(type: .person, pattern: "\\b\(initial)\\.?\\s+\(lastName)\\b", replacement: replacement, isEnabled: true))
            }
        }

        // V3-D1: standalone name tokens ("Priya will bring it.") previously
        // survived redaction. Redact each name part on its own — over-redaction
        // is the safe failure mode for a privacy feature; a leaked name is not.
        for part in parts where part.count >= 2 {
            let token = NSRegularExpression.escapedPattern(for: part)
            rules.append(RedactionRule(type: .person, pattern: "\\b\(token)\\b", replacement: replacement, isEnabled: true))
        }

        if let emailAddr = email, !emailAddr.isEmpty {
            let escapedEmail = NSRegularExpression.escapedPattern(for: emailAddr)
            rules.append(RedactionRule(type: .person, pattern: escapedEmail, replacement: "[REDACTED EMAIL]", isEnabled: true))
            if let localPart = emailAddr.split(separator: "@").first {
                let escapedLocal = NSRegularExpression.escapedPattern(for: String(localPart))
                rules.append(RedactionRule(type: .person, pattern: "\\b\(escapedLocal)\\b", replacement: "[REDACTED]", isEnabled: true))
            }
        }

        return rules
    }

    static func redactPerson(
        emails: [MBOXParser.RawEmail],
        name: String,
        email: String? = nil,
        replacement: String = "[REDACTED PERSON]"
    ) -> [RedactedEmail] {
        let rules = personRedactionRules(name: name, email: email, replacement: replacement)
        return redactBatch(emails: emails, rules: rules)
    }

    // MARK: - Redacted Output

    struct RedactedEmail: Identifiable {
        let id: UUID
        let subject: String
        let from: String
        let to: String
        let body: String
        let redactionCount: Int
    }

    // MARK: - Default Rules

    static let defaultRules: [RedactionRule] = [
        // SSN with dashes, spaces, or no separator
        RedactionRule(
            type: .ssn,
            pattern: #"\b(?!000|666|9\d{2})\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b"#,
            replacement: "[REDACTED-SSN]"
        ),
        // Credit card: 13-19 digits with optional separators (Visa, MC, Amex, Discover)
        RedactionRule(
            type: .creditCard,
            pattern: #"\b(?:4\d{3}|5[1-5]\d{2}|3[47]\d{2}|6(?:011|5\d{2}))[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}\b"#,
            replacement: "[REDACTED-CC]"
        ),
        // US/Canada phone: (xxx) xxx-xxxx, xxx-xxx-xxxx, +1 xxx xxx xxxx
        RedactionRule(
            type: .phoneNumber,
            pattern: #"(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b"#,
            replacement: "[REDACTED-PHONE]"
        ),
        // International phone: +xx xx xxxx xxxx (UK, EU, India, etc.)
        RedactionRule(
            type: .phoneNumber,
            pattern: #"\+\d{1,3}[\s.-]\d{2,4}[\s.-]\d{3,4}[\s.-]?\d{3,6}"#,
            replacement: "[REDACTED-PHONE]"
        ),
        RedactionRule(
            type: .emailAddress,
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            replacement: "[REDACTED-EMAIL]"
        ),
        // DOB with numeric date (validates month 1-12, day 1-31)
        RedactionRule(
            type: .dateOfBirth,
            pattern: #"(?i)(?:DOB|date\s*of\s*birth|born|birthday)\s*:?\s*(?:0?[1-9]|1[0-2])[/\-\.](?:0?[1-9]|[12]\d|3[01])[/\-\.]\d{2,4}"#,
            replacement: "[REDACTED-DOB]"
        ),
        // DOB with month name
        RedactionRule(
            type: .dateOfBirth,
            pattern: #"(?i)(?:DOB|date\s*of\s*birth|born|birthday)\s*:?\s*(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s*\d{2,4}"#,
            replacement: "[REDACTED-DOB]"
        ),
    ]

    // MARK: - Redaction Logic

    /// Apply all enabled rules to a single text string.
    /// Returns the redacted text and the total count of redactions performed.
    static func redact(text: String, rules: [RedactionRule]) -> (redacted: String, count: Int) {
        var result = text
        var totalCount = 0

        for rule in rules where rule.isEnabled {
            // V3-D1: patterns must be case-insensitive — "priya sharma" in a
            // body must not slip past a "Priya Sharma" rule.
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                redactionLog.warning("Invalid regex pattern for rule \(rule.type.rawValue): \(rule.pattern)")
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            let matchCount = regex.numberOfMatches(in: result, range: range)
            totalCount += matchCount
            let escapedReplacement = NSRegularExpression.escapedTemplate(for: rule.replacement)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: escapedReplacement)
        }

        return (result, totalCount)
    }

    /// Redact all relevant fields of an email.
    static func redactEmail(_ email: MBOXParser.RawEmail, rules: [RedactionRule]) -> RedactedEmail {
        let (redactedSubject, subjectCount) = redact(text: email.headers["Subject"] ?? "", rules: rules)
        let (redactedFrom, fromCount) = redact(text: email.headers["From"] ?? "", rules: rules)
        let (redactedTo, toCount) = redact(text: email.headers["To"] ?? "", rules: rules)

        let (redactedPlain, plainCount) = redact(text: email.plainBody, rules: rules)
        let (redactedHtml, htmlCount) = redact(text: email.htmlBody, rules: rules)
        let redactedBody = redactedPlain.isEmpty ? redactedHtml : redactedPlain
        let bodyCount = plainCount + htmlCount

        let ccText = email.headers["Cc"] ?? ""
        let (_, ccCount) = redact(text: ccText, rules: rules)
        let totalRedactions = subjectCount + fromCount + toCount + bodyCount + ccCount

        return RedactedEmail(
            id: email.id,
            subject: redactedSubject,
            from: redactedFrom,
            to: redactedTo,
            body: redactedBody,
            redactionCount: totalRedactions
        )
    }

    /// Redact a batch of emails.
    static func redactBatch(emails: [MBOXParser.RawEmail], rules: [RedactionRule]) -> [RedactedEmail] {
        emails.map { redactEmail($0, rules: rules) }
    }

    // MARK: - Redaction Validation (LAW-14)

    /// Independent post-redaction check: re-scans OUTPUT text for target
    /// terms. Returns the terms still present (case-insensitive), so a
    /// production/export can be blocked until the output is actually clean.
    /// This is deliberately not the rule engine — a second pair of eyes.
    static func validateRedaction(text: String, targets: [String]) -> [String] {
        let lowered = text.lowercased()
        return targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 2 }
            .filter { lowered.contains($0.lowercased()) }
    }

    /// Validates a redacted email against a person's identifiers (full name,
    /// each name part, email address, address local part). Empty result =
    /// clean; non-empty = leaked terms that must block the export.
    static func validatePersonRedaction(_ redacted: RedactedEmail, name: String, email: String? = nil) -> [String] {
        var targets = [name]
        targets.append(contentsOf: name.components(separatedBy: .whitespaces).filter { $0.count >= 2 })
        if let email, !email.isEmpty {
            targets.append(email)
            if let local = email.split(separator: "@").first, local.count >= 2 {
                targets.append(String(local))
            }
        }
        let combined = [redacted.subject, redacted.from, redacted.to, redacted.body].joined(separator: "\n")
        return Array(Set(validateRedaction(text: combined, targets: targets))).sorted()
    }

    // MARK: - Redaction Log Export

    /// Generate a CSV log documenting all redactions performed.
    /// Includes a sanitized snippet (first 3 + last 3 characters) of the original value.
    static func generateRedactionLog(emails: [MBOXParser.RawEmail], rules: [RedactionRule]) -> Data {
        var csv = "EmailID,Field,OriginalSnippet,RedactionType,Count\n"

        func csvEscape(_ s: String) -> String {
            var v = s
            if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "") + "\""
        }

        func snippet(_ value: String) -> String {
            guard value.count > 4 else { return String(repeating: "*", count: value.count) }
            let prefix = String(value.prefix(2))
            return "\(prefix)...\(String(repeating: "*", count: max(1, value.count - 2)))"
        }

        let enabledRules = rules.filter(\.isEnabled)

        for email in emails {
            let fields: [(name: String, text: String)] = [
                ("Subject", email.headers["Subject"] ?? ""),
                ("From", email.headers["From"] ?? ""),
                ("To", email.headers["To"] ?? ""),
                ("Body", email.plainBody.isEmpty ? email.htmlBody : email.plainBody),
            ]

            for (fieldName, fieldText) in fields {
                for rule in enabledRules {
                    guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else { continue }
                    let nsText = fieldText as NSString
                    let range = NSRange(location: 0, length: nsText.length)
                    let matches = regex.matches(in: fieldText, range: range)

                    if !matches.isEmpty {
                        for match in matches {
                            if let matchRange = Range(match.range, in: fieldText) {
                                let original = String(fieldText[matchRange])
                                csv += "\(csvEscape(email.id.uuidString)),"
                                csv += "\(csvEscape(fieldName)),"
                                csv += "\(csvEscape(snippet(original))),"
                                csv += "\(csvEscape(rule.type.rawValue)),"
                                csv += "1\n"
                            }
                        }
                    }
                }
            }
        }

        redactionLog.info("Generated redaction log for \(emails.count) emails")
        return csv.data(using: .utf8) ?? Data()
    }
}

// MARK: - RedactionConfigView

struct RedactionConfigView: View {
    let emails: [MBOXParser.RawEmail]

    @State private var rules: [RedactionEngine.RedactionRule] = RedactionEngine.defaultRules
    @State private var previewEmail: MBOXParser.RawEmail?
    @State private var previewResult: RedactionEngine.RedactedEmail?
    @State private var showAddRule = false
    @State private var newRulePattern = ""
    @State private var newRuleReplacement = "[REDACTED]"
    @State private var newRuleCategory: RedactionEngine.PIICategory = .custom
    @State private var exportMessage: String?
    @State private var showExportMessage = false
    @State private var showPreview = false
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            // Header
            Label("PII Redaction", systemImage: "eye.slash.fill")
                .font(Typography.title3)
                .foregroundColor(AppColors.primary)
                .accessibilityAddTraits(.isHeader)

            Text("Automatically redact personally identifiable information from email exports.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            Divider()
                .background(AppColors.separatorLight)

            // Rules List
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Redaction Rules")
                    .font(Typography.headline)

                ForEach($rules) { $rule in
                    HStack(spacing: Spacing.small) {
                        Toggle(isOn: $rule.isEnabled) {
                            HStack(spacing: Spacing.xSmall) {
                                Image(systemName: rule.type.icon)
                                    .foregroundColor(rule.isEnabled ? AppColors.primary : AppColors.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                                    Text(rule.type.rawValue)
                                        .font(Typography.callout)
                                        .foregroundColor(rule.isEnabled ? .primary : AppColors.secondary)

                                    Text(rule.replacement)
                                        .font(Typography.caption2)
                                        .foregroundColor(AppColors.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .accessibilityLabel("\(rule.type.rawValue) redaction")
                        .accessibilityHint(rule.isEnabled ? "Enabled" : "Disabled")
                    }
                    .padding(.vertical, Spacing.xxSmall)
                }
            }
            .padding(Spacing.small)
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.medium)

            // Add Custom Rule
            DisclosureGroup("Add Custom Rule", isExpanded: $showAddRule) {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Picker("Category", selection: $newRuleCategory) {
                        ForEach(RedactionEngine.PIICategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .accessibilityLabel("Rule category")

                    TextField("Regex Pattern", text: $newRulePattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Regular expression pattern")

                    TextField("Replacement Text", text: $newRuleReplacement)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Replacement text for matched content")

                    Button {
                        guard !newRulePattern.isEmpty else { return }
                        let rule = RedactionEngine.RedactionRule(
                            type: newRuleCategory,
                            pattern: newRulePattern,
                            replacement: newRuleReplacement
                        )
                        rules.append(rule)
                        newRulePattern = ""
                        newRuleReplacement = "[REDACTED]"
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(newRulePattern.isEmpty)
                    .accessibilityHint("Adds the custom redaction rule to the list")
                }
                .padding(.top, Spacing.xSmall)
            }
            .font(Typography.subheadline)

            // Preview Panel
            if showPreview, let result = previewResult {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    HStack {
                        Text("Redaction Preview")
                            .font(Typography.headline)
                        Spacer()
                        Text("\(result.redactionCount) redactions")
                            .font(Typography.caption1)
                            .foregroundColor(result.redactionCount > 0 ? AppColors.warning : AppColors.success)
                    }

                    Group {
                        HStack(spacing: Spacing.xSmall) {
                            Text("From:")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                            Text(result.from)
                                .font(Typography.caption1)
                                .lineLimit(1)
                        }
                        HStack(spacing: Spacing.xSmall) {
                            Text("Subject:")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                            Text(result.subject)
                                .font(Typography.caption1)
                                .lineLimit(1)
                        }

                        ScrollView {
                            Text(result.body.prefix(500) + (result.body.count > 500 ? "..." : ""))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .padding(Spacing.small)
                .background(AppColors.backgroundTertiary)
                .cornerRadius(CornerRadius.small)
            }

            // Actions
            HStack(spacing: Spacing.small) {
                Button {
                    if let sample = emails.first {
                        previewEmail = sample
                        previewResult = RedactionEngine.redactEmail(sample, rules: rules)
                        showPreview = true
                    }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(emails.isEmpty)
                .accessibilityHint("Shows a preview of redaction applied to the first email")

                Button {
                    exportRedacted()
                } label: {
                    Label("Redact & Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(emails.isEmpty)
                .accessibilityHint("Applies redaction rules and exports all emails")
            }

            if let message = exportMessage, showExportMessage {
                Label(message, systemImage: "doc.text")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.info)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
        #if os(macOS)
        .frame(minWidth: 420, maxWidth: 650)
        #else
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    // MARK: - Export

    private func exportRedacted() {
        let redacted = RedactionEngine.redactBatch(emails: emails, rules: rules)
        let totalRedactions = redacted.reduce(0) { $0 + $1.redactionCount }

        // Build a combined text export
        var output = "REDACTED EMAIL EXPORT\n"
        output += "Total Emails: \(redacted.count)\n"
        output += "Total Redactions: \(totalRedactions)\n"
        output += String(repeating: "=", count: 60) + "\n\n"

        for item in redacted {
            output += "From: \(item.from)\n"
            output += "To: \(item.to)\n"
            output += "Subject: \(item.subject)\n"
            output += String(repeating: "-", count: 40) + "\n"
            output += item.body + "\n"
            output += String(repeating: "=", count: 60) + "\n\n"
        }

        let data = output.data(using: .utf8) ?? Data()

        // Also generate the redaction log
        let logData = RedactionEngine.generateRedactionLog(emails: emails, rules: rules)

        #if os(macOS)
        if PlatformFileSaver.saveData(data, suggestedName: "RedactedExport.txt") {
            // Save redaction log alongside
            _ = PlatformFileSaver.saveData(logData, suggestedName: "RedactionLog.csv")
            exportMessage = "Exported \(redacted.count) redacted emails with \(totalRedactions) redactions."
            ForensicManager.shared.logAction(
                "Redacted Export",
                detail: "\(redacted.count) emails exported with \(totalRedactions) redactions applied"
            )
        } else {
            exportMessage = "Export cancelled."
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RedactedExport.txt")
        do {
            try data.write(to: url, options: .atomic)
            let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("RedactionLog.csv")
            try logData.write(to: logURL, options: .atomic)
            shareItems = [url, logURL]
            showShareSheet = true
            ForensicManager.shared.logAction(
                "Redacted Export",
                detail: "\(redacted.count) emails exported with \(totalRedactions) redactions applied"
            )
        } catch {
            exportMessage = "Failed to export redacted emails."
        }
        #endif
        showExportMessage = true
    }
}
