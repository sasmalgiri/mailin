//
//  SmartNotificationManager.swift
//  mailin
//
//  Detects suspicious patterns in email archives and sends local notifications
//

import Foundation
import UserNotifications

// MARK: - Alert Types

enum SmartAlertType: String, Codable, CaseIterable {
    case phishingDetected = "Phishing Detected"
    case unusualVolume = "Unusual Volume"
    case piiExposure = "PII Exposure"
    case newSenderBurst = "New Sender Burst"
    case sentimentShift = "Sentiment Shift"

    var icon: String {
        switch self {
        case .phishingDetected: return "exclamationmark.shield.fill"
        case .unusualVolume: return "chart.bar.xaxis.ascending"
        case .piiExposure: return "eye.trianglebadge.exclamationmark.fill"
        case .newSenderBurst: return "person.3.fill"
        case .sentimentShift: return "heart.slash.fill"
        }
    }
}

enum SmartAlertSeverity: String, Codable, Comparable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: SmartAlertSeverity, rhs: SmartAlertSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - SmartAlert

struct SmartAlert: Identifiable {
    let id: UUID
    let type: SmartAlertType
    let severity: SmartAlertSeverity
    let title: String
    let message: String
    let emailIDs: [UUID]

    init(type: SmartAlertType, severity: SmartAlertSeverity, title: String, message: String, emailIDs: [UUID] = []) {
        self.id = UUID()
        self.type = type
        self.severity = severity
        self.title = title
        self.message = message
        self.emailIDs = emailIDs
    }
}

// MARK: - SmartNotificationManager

@MainActor
final class SmartNotificationManager: ObservableObject {
    @Published var alerts: [SmartAlert] = []

    // MARK: - Notification Authorization

    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                #if DEBUG
                print("[SmartNotificationManager] Authorization error: \(error.localizedDescription)")
                #endif
            }
            completion?(granted)
        }
    }

    // MARK: - Analyze for Alerts

    /// Runs all detection heuristics against the provided email set.
    func analyzeForAlerts(emails: [MBOXParser.RawEmail]) -> [SmartAlert] {
        var detected: [SmartAlert] = []

        detected.append(contentsOf: detectPhishing(emails: emails))
        detected.append(contentsOf: detectUnusualVolume(emails: emails))
        detected.append(contentsOf: detectPIIExposure(emails: emails))
        detected.append(contentsOf: detectNewSenderBurst(emails: emails))
        detected.append(contentsOf: detectSentimentShift(emails: emails))

        // Sort by severity descending
        detected.sort { $0.severity > $1.severity }
        alerts = detected
        return detected
    }

    // MARK: - Local Notifications

    func sendLocalNotification(for alert: SmartAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = alert.severity == .high ? .defaultCritical : .default

        switch alert.severity {
        case .high:
            content.interruptionLevel = .critical
        case .medium:
            content.interruptionLevel = .timeSensitive
        case .low:
            content.interruptionLevel = .passive
        }

        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            #if DEBUG
            if let error = error {
                print("[SmartNotificationManager] Notification error: \(error.localizedDescription)")
            }
            #endif
        }
    }

    /// Convenience: analyze, then send a local notification for every high or medium alert.
    func analyzeAndNotify(emails: [MBOXParser.RawEmail]) {
        let detected = analyzeForAlerts(emails: emails)
        for alert in detected where alert.severity >= .medium {
            sendLocalNotification(for: alert)
        }
    }

    // MARK: - Detection: Phishing

    private func detectPhishing(emails: [MBOXParser.RawEmail]) -> [SmartAlert] {
        let flags = EmailNLPEngine.detectPhishing(in: emails)
        guard !flags.isEmpty else { return [] }

        // Group by risk level
        var highIDs: [UUID] = []
        var mediumIDs: [UUID] = []
        var lowIDs: [UUID] = []

        for flag in flags {
            switch flag.riskLevel {
            case .high: highIDs.append(flag.email.id)
            case .medium: mediumIDs.append(flag.email.id)
            case .low: lowIDs.append(flag.email.id)
            }
        }

        var alerts: [SmartAlert] = []

        if !highIDs.isEmpty {
            alerts.append(SmartAlert(
                type: .phishingDetected,
                severity: .high,
                title: "High-Risk Phishing Detected",
                message: "\(highIDs.count) email\(highIDs.count == 1 ? "" : "s") flagged as high-risk phishing. Review immediately.",
                emailIDs: highIDs
            ))
        }

        if !mediumIDs.isEmpty {
            alerts.append(SmartAlert(
                type: .phishingDetected,
                severity: .medium,
                title: "Suspicious Emails Detected",
                message: "\(mediumIDs.count) email\(mediumIDs.count == 1 ? "" : "s") flagged as medium-risk. Manual review recommended.",
                emailIDs: mediumIDs
            ))
        }

        if !lowIDs.isEmpty {
            alerts.append(SmartAlert(
                type: .phishingDetected,
                severity: .low,
                title: "Low-Risk Phishing Indicators",
                message: "\(lowIDs.count) email\(lowIDs.count == 1 ? "" : "s") have minor phishing indicators.",
                emailIDs: lowIDs
            ))
        }

        return alerts
    }

    // MARK: - Detection: Unusual Volume

    private func detectUnusualVolume(emails: [MBOXParser.RawEmail]) -> [SmartAlert] {
        guard emails.count >= 7 else { return [] } // need enough data for comparison

        // Group emails by day
        var dailyCounts: [String: (count: Int, ids: [UUID])] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
            let dayKey = dayFormatter.string(from: date)
            dailyCounts[dayKey, default: (count: 0, ids: [])].count += 1
            dailyCounts[dayKey, default: (count: 0, ids: [])].ids.append(email.id)
        }

        guard dailyCounts.count >= 2 else { return [] }

        let sortedDays = dailyCounts.keys.sorted()
        let allCounts = sortedDays.map { dailyCounts[$0]?.count ?? 0 }

        // Use the last 30 days (or all available) as baseline
        let baselineCount = min(allCounts.count - 1, 30)
        guard baselineCount >= 1 else { return [] }
        let baselineCounts = Array(allCounts.prefix(baselineCount))
        let baselineAverage = Double(baselineCounts.reduce(0, +)) / Double(baselineCounts.count)

        guard baselineAverage > 0 else { return [] }

        var alerts: [SmartAlert] = []

        // Check the most recent day
        if let lastDay = sortedDays.last, let lastDayData = dailyCounts[lastDay] {
            let ratio = Double(lastDayData.count) / baselineAverage
            if ratio > 2.0 {
                let severity: SmartAlertSeverity = ratio > 5.0 ? .high : (ratio > 3.0 ? .medium : .low)
                alerts.append(SmartAlert(
                    type: .unusualVolume,
                    severity: severity,
                    title: "Unusual Email Volume",
                    message: "\(lastDayData.count) emails on \(lastDay) -- \(String(format: "%.1f", ratio))x the 30-day average of \(String(format: "%.1f", baselineAverage)).",
                    emailIDs: lastDayData.ids
                ))
            }
        }

        return alerts
    }

    // MARK: - Detection: PII Exposure

    private func detectPIIExposure(emails: [MBOXParser.RawEmail]) -> [SmartAlert] {
        // Regex patterns for common PII
        let ssnPattern = #"\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b"#
        let creditCardPattern = #"\b(?:4\d{3}|5[1-5]\d{2}|3[47]\d{2}|6(?:011|5\d{2}))[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b"#
        let phonePattern = #"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#

        let ssnRegex = try? NSRegularExpression(pattern: ssnPattern)
        let ccRegex = try? NSRegularExpression(pattern: creditCardPattern)
        let phoneRegex = try? NSRegularExpression(pattern: phonePattern)

        var flaggedIDs: [UUID] = []
        var ssnCount = 0
        var ccCount = 0
        var phoneCount = 0

        for email in emails {
            let body = emailBodyText(for: email)
            guard !body.isEmpty else { continue }
            let nsBody = body as NSString
            let range = NSRange(location: 0, length: nsBody.length)

            var hasPII = false

            if let matches = ssnRegex?.numberOfMatches(in: body, range: range), matches > 0 {
                ssnCount += matches
                hasPII = true
            }
            if let matches = ccRegex?.numberOfMatches(in: body, range: range), matches > 0 {
                ccCount += matches
                hasPII = true
            }
            if let matches = phoneRegex?.numberOfMatches(in: body, range: range), matches > 0 {
                // Phone numbers are common, only flag if there are multiple or combined with other PII
                phoneCount += matches
                if matches >= 3 || ssnCount > 0 || ccCount > 0 {
                    hasPII = true
                }
            }

            if hasPII {
                flaggedIDs.append(email.id)
            }
        }

        guard !flaggedIDs.isEmpty else { return [] }

        var details: [String] = []
        if ssnCount > 0 { details.append("\(ssnCount) SSN-like pattern\(ssnCount == 1 ? "" : "s")") }
        if ccCount > 0 { details.append("\(ccCount) credit card-like pattern\(ccCount == 1 ? "" : "s")") }
        if phoneCount > 0 { details.append("\(phoneCount) phone number\(phoneCount == 1 ? "" : "s")") }

        let severity: SmartAlertSeverity
        if ssnCount > 0 || ccCount > 0 {
            severity = .high
        } else {
            severity = .medium
        }

        return [SmartAlert(
            type: .piiExposure,
            severity: severity,
            title: "Potential PII Exposure",
            message: "Found \(details.joined(separator: ", ")) across \(flaggedIDs.count) email\(flaggedIDs.count == 1 ? "" : "s").",
            emailIDs: flaggedIDs
        )]
    }

    // MARK: - Detection: New Sender Burst

    private func detectNewSenderBurst(emails: [MBOXParser.RawEmail]) -> [SmartAlert] {
        guard emails.count >= 5 else { return [] }

        // Sort emails by date to determine which senders appeared first
        let sortedEmails = emails.sorted { lhs, rhs in
            let lhsDate = MBOXParser.parseDate(lhs.headers["Date"]) ?? .distantPast
            let rhsDate = MBOXParser.parseDate(rhs.headers["Date"]) ?? .distantPast
            return lhsDate < rhsDate
        }

        // Determine the midpoint date (split into "historical" and "recent" halves)
        // For the "new sender" check: senders who appear only in the last 24h window
        guard let latestDate = MBOXParser.parseDate(sortedEmails.last?.headers["Date"]) else { return [] }
        let cutoff = Calendar.current.date(byAdding: .hour, value: -24, to: latestDate) ?? latestDate

        // Collect all senders before the cutoff
        var historicalSenders = Set<String>()
        var recentSenderCounts: [String: [UUID]] = [:]

        for email in sortedEmails {
            let sender = extractEmailAddress(from: email.headers["From"] ?? "").lowercased()
            guard !sender.isEmpty else { continue }

            let emailDate = MBOXParser.parseDate(email.headers["Date"]) ?? .distantPast
            if emailDate < cutoff {
                historicalSenders.insert(sender)
            } else {
                recentSenderCounts[sender, default: []].append(email.id)
            }
        }

        // Find new senders in the recent window with >5 emails
        var alerts: [SmartAlert] = []
        for (sender, ids) in recentSenderCounts {
            if !historicalSenders.contains(sender) && ids.count > 5 {
                let severity: SmartAlertSeverity = ids.count > 20 ? .high : (ids.count > 10 ? .medium : .low)
                alerts.append(SmartAlert(
                    type: .newSenderBurst,
                    severity: severity,
                    title: "New Sender Burst",
                    message: "\(ids.count) emails from new sender \(sender) within the last 24 hours.",
                    emailIDs: ids
                ))
            }
        }

        return alerts
    }

    // MARK: - Detection: Sentiment Shift

    private func detectSentimentShift(emails: [MBOXParser.RawEmail]) -> [SmartAlert] {
        guard emails.count >= 10 else { return [] }

        // Sort by date
        let sortedEmails = emails.sorted { lhs, rhs in
            let lhsDate = MBOXParser.parseDate(lhs.headers["Date"]) ?? .distantPast
            let rhsDate = MBOXParser.parseDate(rhs.headers["Date"]) ?? .distantPast
            return lhsDate < rhsDate
        }

        // Split into two halves: prior period and recent period
        let midpoint = sortedEmails.count / 2
        let priorEmails = Array(sortedEmails.prefix(midpoint))
        let recentEmails = Array(sortedEmails.suffix(from: midpoint))

        let priorSentiment = EmailNLPEngine.averageSentiment(of: priorEmails)
        let recentSentiment = EmailNLPEngine.averageSentiment(of: recentEmails)

        let shift = recentSentiment.average - priorSentiment.average

        // Alert if sentiment dropped significantly (at least 0.4 points)
        guard shift < -0.4 else { return [] }

        let severity: SmartAlertSeverity
        if shift < -0.6 {
            severity = .high
        } else if shift < -0.4 {
            severity = .medium
        } else {
            severity = .low
        }

        let recentIDs = recentEmails.map(\.id)

        return [SmartAlert(
            type: .sentimentShift,
            severity: severity,
            title: "Sentiment Decline Detected",
            message: "Average sentiment shifted from \(String(format: "%.2f", priorSentiment.average)) (\(priorSentiment.label)) to \(String(format: "%.2f", recentSentiment.average)) (\(recentSentiment.label)) in the recent period.",
            emailIDs: recentIDs
        )]
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

    private func extractEmailAddress(from header: String) -> String {
        // Extract email from "Display Name <email@domain.com>" or plain "email@domain.com"
        if let openAngle = header.firstIndex(of: "<"),
           let closeAngle = header.firstIndex(of: ">"),
           openAngle < closeAngle {
            let start = header.index(after: openAngle)
            return String(header[start..<closeAngle]).trimmingCharacters(in: .whitespaces)
        }
        // If no angle brackets, check for @ sign
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") {
            return trimmed
        }
        return ""
    }
}
