//
//  AIDigestGenerator.swift
//  mailin
//
//  Generates summary digests from email archives using NLP analysis — no AI models required.
//

import Foundation
import NaturalLanguage

struct AIDigestGenerator {

    // MARK: - Types

    struct DigestSection: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let items: [DigestItem]
    }

    struct DigestItem: Identifiable {
        let id = UUID()
        let headline: String
        let detail: String
        let emailIDs: [UUID]
        let priority: Priority

        enum Priority: Int, Comparable {
            case low = 0, medium = 1, high = 2

            static func < (lhs: Priority, rhs: Priority) -> Bool {
                lhs.rawValue < rhs.rawValue
            }

            var label: String {
                switch self {
                case .low: return "Low"
                case .medium: return "Medium"
                case .high: return "High"
                }
            }
        }
    }

    enum TimePeriod: String, CaseIterable {
        case today = "Today"
        case lastWeek = "Last 7 Days"
        case lastMonth = "Last 30 Days"
        case custom = "Custom Range"
    }

    // MARK: - Public Entry Point

    static func generateDigest(
        emails: [MBOXParser.RawEmail],
        period: TimePeriod,
        customStart: Date? = nil,
        customEnd: Date? = nil
    ) -> [DigestSection] {
        let filtered = filterEmails(emails, period: period, customStart: customStart, customEnd: customEnd)
        guard !filtered.isEmpty else { return [] }

        var sections: [DigestSection] = []

        // 1. Statistics
        if let stats = statisticsSection(filtered, allEmails: emails) {
            sections.append(stats)
        }

        // 2. Key Conversations
        if let conversations = keyConversationsSection(filtered) {
            sections.append(conversations)
        }

        // 3. Action Items
        if let actions = actionItemsSection(filtered) {
            sections.append(actions)
        }

        // 4. New Contacts
        if let contacts = newContactsSection(filtered, allEmails: emails) {
            sections.append(contacts)
        }

        // 5. Sentiment Summary
        if let sentiment = sentimentSection(filtered) {
            sections.append(sentiment)
        }

        // 6. Attachments Overview
        if let attachments = attachmentsSection(filtered) {
            sections.append(attachments)
        }

        return sections
    }

    // MARK: - 1. Statistics

    private static func statisticsSection(_ emails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail]) -> DigestSection? {
        let totalCount = emails.count
        let sentCount = emails.filter { $0.messageType == "sent" }.count
        let receivedCount = totalCount - sentCount

        // Top senders
        var senderCounts: [String: Int] = [:]
        for email in emails {
            let sender = email.headers["From"] ?? "Unknown"
            senderCounts[sender, default: 0] += 1
        }
        let topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(3)

        // Busiest day
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        var dayCounts: [String: Int] = [:]
        for email in emails {
            guard let dateStr = email.headers["Date"],
                  let date = MBOXParser.parseDate(dateStr) else { continue }
            let day = dayFormatter.string(from: date)
            dayCounts[day, default: 0] += 1
        }
        let busiestDay = dayCounts.max { $0.value < $1.value }

        // Busiest hour
        var hourCounts: [Int: Int] = [:]
        for email in emails {
            guard let dateStr = email.headers["Date"],
                  let date = MBOXParser.parseDate(dateStr) else { continue }
            let hour = Calendar.current.component(.hour, from: date)
            hourCounts[hour, default: 0] += 1
        }
        let busiestHour = hourCounts.max { $0.value < $1.value }

        var items: [DigestItem] = []

        items.append(DigestItem(
            headline: "Total: \(totalCount) emails",
            detail: "\(sentCount) sent, \(receivedCount) received",
            emailIDs: [],
            priority: .medium
        ))

        if let busiestDay = busiestDay {
            items.append(DigestItem(
                headline: "Busiest day: \(busiestDay.key)",
                detail: "\(busiestDay.value) emails on \(busiestDay.key)s",
                emailIDs: [],
                priority: .low
            ))
        }

        if let busiestHour = busiestHour {
            let hourLabel = busiestHour.key < 12 ? "\(busiestHour.key == 0 ? 12 : busiestHour.key) AM" : "\(busiestHour.key == 12 ? 12 : busiestHour.key - 12) PM"
            items.append(DigestItem(
                headline: "Peak hour: \(hourLabel)",
                detail: "\(busiestHour.value) emails around \(hourLabel)",
                emailIDs: [],
                priority: .low
            ))
        }

        if !topSenders.isEmpty {
            let senderList = topSenders.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            items.append(DigestItem(
                headline: "Top senders",
                detail: senderList,
                emailIDs: [],
                priority: .low
            ))
        }

        return DigestSection(title: "Statistics", icon: "chart.bar.fill", items: items)
    }

    // MARK: - 2. Key Conversations

    private static func keyConversationsSection(_ emails: [MBOXParser.RawEmail]) -> DigestSection? {
        // Group by thread (normalized subject)
        var threads: [String: (emails: [MBOXParser.RawEmail], participants: Set<String>)] = [:]

        for email in emails {
            let subject = normalizeSubject(email.headers["Subject"] ?? "(No Subject)")
            var entry = threads[subject] ?? (emails: [], participants: Set<String>())
            entry.emails.append(email)
            if let from = email.headers["From"] {
                entry.participants.insert(from)
            }
            threads[subject] = entry
        }

        let topThreads = threads
            .sorted { $0.value.emails.count > $1.value.emails.count }
            .prefix(5)

        guard !topThreads.isEmpty else { return nil }

        let items = topThreads.map { (subject, data) in
            let participantList = data.participants.prefix(3).joined(separator: ", ")
            let suffix = data.participants.count > 3 ? " +\(data.participants.count - 3) more" : ""
            return DigestItem(
                headline: subject,
                detail: "\(data.emails.count) messages with \(participantList)\(suffix)",
                emailIDs: data.emails.map(\.id),
                priority: data.emails.count > 10 ? .high : (data.emails.count > 5 ? .medium : .low)
            )
        }

        return DigestSection(title: "Key Conversations", icon: "bubble.left.and.bubble.right.fill", items: items)
    }

    // MARK: - 3. Action Items

    private static func actionItemsSection(_ emails: [MBOXParser.RawEmail]) -> DigestSection? {
        let urgentKeywords = ["urgent", "asap", "action required", "deadline", "critical", "immediate", "time-sensitive", "respond by", "reply by", "due date", "overdue"]
        let questionKeywords = ["?", "could you", "can you", "would you", "please", "do you", "are you able"]

        var items: [DigestItem] = []

        for email in emails {
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let body = bodyText(for: email).lowercased()
            let prefix = String(body.prefix(1000))

            // Urgent emails
            let urgentMatches = urgentKeywords.filter { subject.contains($0) || prefix.contains($0) }
            if !urgentMatches.isEmpty {
                items.append(DigestItem(
                    headline: email.headers["Subject"] ?? "(No Subject)",
                    detail: "From \(email.headers["From"] ?? "Unknown") — contains: \(urgentMatches.joined(separator: ", "))",
                    emailIDs: [email.id],
                    priority: .high
                ))
                continue
            }

            // Emails with direct questions
            let hasQuestion = questionKeywords.filter { prefix.contains($0) }
            if hasQuestion.count >= 2 {
                items.append(DigestItem(
                    headline: email.headers["Subject"] ?? "(No Subject)",
                    detail: "From \(email.headers["From"] ?? "Unknown") — contains questions that may need a response",
                    emailIDs: [email.id],
                    priority: .medium
                ))
            }
        }

        guard !items.isEmpty else { return nil }

        let sortedItems = items.sorted { $0.priority > $1.priority }
        return DigestSection(title: "Action Items", icon: "exclamationmark.bubble.fill", items: Array(sortedItems.prefix(10)))
    }

    // MARK: - 4. New Contacts

    private static func newContactsSection(_ periodEmails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail]) -> DigestSection? {
        // Find sender addresses that appear in the period but not before
        let sorted = allEmails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }

        let periodIDs = Set(periodEmails.map(\.id))

        var historicalSenders = Set<String>()
        for email in sorted {
            if periodIDs.contains(email.id) { break }
            if let from = email.headers["From"] {
                historicalSenders.insert(extractEmailAddress(from: from).lowercased())
            }
        }

        var newSenderData: [String: (displayName: String, ids: [UUID])] = [:]
        for email in periodEmails {
            guard let from = email.headers["From"] else { continue }
            let address = extractEmailAddress(from: from).lowercased()
            if !historicalSenders.contains(address) && !address.isEmpty {
                var entry = newSenderData[address] ?? (displayName: from, ids: [])
                entry.ids.append(email.id)
                newSenderData[address] = entry
            }
        }

        guard !newSenderData.isEmpty else { return nil }

        let items = newSenderData
            .sorted { $0.value.ids.count > $1.value.ids.count }
            .prefix(10)
            .map { (address, data) in
                DigestItem(
                    headline: data.displayName,
                    detail: "\(data.ids.count) email\(data.ids.count == 1 ? "" : "s") from new contact",
                    emailIDs: data.ids,
                    priority: data.ids.count > 3 ? .medium : .low
                )
            }

        return DigestSection(title: "New Contacts", icon: "person.badge.plus", items: items)
    }

    // MARK: - 5. Sentiment Summary

    private static func sentimentSection(_ emails: [MBOXParser.RawEmail]) -> DigestSection? {
        let sentimentData = EmailNLPEngine.averageSentiment(of: emails)

        var items: [DigestItem] = []

        items.append(DigestItem(
            headline: "Overall tone: \(sentimentData.label)",
            detail: "Average sentiment score: \(String(format: "%.2f", sentimentData.average)). \(sentimentData.positive) positive, \(sentimentData.neutral) neutral, \(sentimentData.negative) negative.",
            emailIDs: [],
            priority: .medium
        ))

        // Find the most positive and most negative emails
        let sentimentResults = EmailNLPEngine.analyzeSentiment(of: emails)
        if let mostPositive = sentimentResults.max(by: { $0.score < $1.score }), mostPositive.score > 0.3 {
            items.append(DigestItem(
                headline: "Most positive: \(mostPositive.email.headers["Subject"] ?? "(No Subject)")",
                detail: "From \(mostPositive.email.headers["From"] ?? "Unknown") — sentiment: \(String(format: "%.2f", mostPositive.score))",
                emailIDs: [mostPositive.email.id],
                priority: .low
            ))
        }

        if let mostNegative = sentimentResults.min(by: { $0.score < $1.score }), mostNegative.score < -0.3 {
            items.append(DigestItem(
                headline: "Most negative: \(mostNegative.email.headers["Subject"] ?? "(No Subject)")",
                detail: "From \(mostNegative.email.headers["From"] ?? "Unknown") — sentiment: \(String(format: "%.2f", mostNegative.score))",
                emailIDs: [mostNegative.email.id],
                priority: .low
            ))
        }

        return DigestSection(title: "Sentiment Summary", icon: "face.smiling", items: items)
    }

    // MARK: - 6. Attachments Overview

    private static func attachmentsSection(_ emails: [MBOXParser.RawEmail]) -> DigestSection? {
        let withAttachments = emails.filter { !$0.attachments.isEmpty }
        guard !withAttachments.isEmpty else { return nil }

        var items: [DigestItem] = []

        let totalAttachments = withAttachments.reduce(0) { $0 + $1.attachments.count }
        items.append(DigestItem(
            headline: "\(totalAttachments) attachments in \(withAttachments.count) emails",
            detail: "Average \(String(format: "%.1f", Double(totalAttachments) / Double(withAttachments.count))) attachments per email with files",
            emailIDs: withAttachments.map(\.id),
            priority: .low
        ))

        // Group by file type
        var typeCounts: [String: Int] = [:]
        for email in withAttachments {
            for attachment in email.attachments {
                let ext = (attachment.filename as NSString).pathExtension.lowercased()
                let category: String
                if ["pdf"].contains(ext) { category = "PDF" }
                else if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"].contains(ext) { category = "Images" }
                else if ["doc", "docx", "rtf", "txt"].contains(ext) { category = "Documents" }
                else if ["xls", "xlsx", "csv"].contains(ext) { category = "Spreadsheets" }
                else if ["zip", "gz", "tar", "7z", "rar"].contains(ext) { category = "Archives" }
                else if ext.isEmpty { category = "Unknown" }
                else { category = ext.uppercased() }
                typeCounts[category, default: 0] += 1
            }
        }

        if !typeCounts.isEmpty {
            let typeBreakdown = typeCounts
                .sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            items.append(DigestItem(
                headline: "File types",
                detail: typeBreakdown,
                emailIDs: [],
                priority: .low
            ))
        }

        // Largest attachments
        let sortedBySize = withAttachments
            .sorted { $0.attachments.reduce(0) { $0 + $1.size } > $1.attachments.reduce(0) { $0 + $1.size } }
            .prefix(3)

        for email in sortedBySize {
            let totalSize = email.attachments.reduce(0) { $0 + $1.size }
            guard totalSize > 0 else { continue }
            let filenames = email.attachments.map(\.filename).joined(separator: ", ")
            items.append(DigestItem(
                headline: email.headers["Subject"] ?? "(No Subject)",
                detail: "Files: \(filenames) (\(formatSize(totalSize)))",
                emailIDs: [email.id],
                priority: totalSize > 5_000_000 ? .medium : .low
            ))
        }

        return DigestSection(title: "Attachments Overview", icon: "paperclip", items: items)
    }

    // MARK: - Helpers

    private static func filterEmails(_ emails: [MBOXParser.RawEmail], period: TimePeriod, customStart: Date?, customEnd: Date?) -> [MBOXParser.RawEmail] {
        let calendar = Calendar.current
        let now = Date()
        let startDate: Date
        let endDate: Date

        switch period {
        case .today:
            startDate = calendar.startOfDay(for: now)
            endDate = now
        case .lastWeek:
            startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            endDate = now
        case .lastMonth:
            startDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            endDate = now
        case .custom:
            startDate = customStart ?? calendar.date(byAdding: .day, value: -7, to: now) ?? now
            endDate = customEnd ?? now
        }

        return emails.filter { email in
            guard let dateStr = email.headers["Date"],
                  let date = MBOXParser.parseDate(dateStr) else { return false }
            return date >= startDate && date <= endDate
        }
    }

    private static func normalizeSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["re:", "fw:", "fwd:", "re: re:", "fw: fw:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes {
                if s.lowercased().hasPrefix(prefix) {
                    s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return s.isEmpty ? "(No Subject)" : s
    }

    private static func extractEmailAddress(from header: String) -> String {
        if let openAngle = header.firstIndex(of: "<"),
           let closeAngle = header.firstIndex(of: ">"),
           openAngle < closeAngle {
            let start = header.index(after: openAngle)
            return String(header[start..<closeAngle]).trimmingCharacters(in: .whitespaces)
        }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed }
        return ""
    }

    private static func bodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}
