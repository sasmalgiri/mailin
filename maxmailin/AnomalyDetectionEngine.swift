//
//  AnomalyDetectionEngine.swift
//  mailin
//
//  Statistical anomaly detection for email archives — no AI models required.
//

import Foundation
import NaturalLanguage

struct AnomalyDetectionEngine {

    // MARK: - Types

    enum AnomalyType: String, CaseIterable, Identifiable {
        case frequencySpike = "Frequency Spike"
        case unusualHour = "Unusual Hour"
        case newDomain = "New Domain"
        case toneShift = "Tone Shift"
        case largeAttachment = "Large Attachment"
        case recipientAnomaly = "Recipient Anomaly"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .frequencySpike: return "chart.bar.xaxis.ascending"
            case .unusualHour: return "moon.stars.fill"
            case .newDomain: return "globe.badge.chevron.backward"
            case .toneShift: return "waveform.path.ecg"
            case .largeAttachment: return "paperclip.badge.ellipsis"
            case .recipientAnomaly: return "person.3.sequence.fill"
            }
        }

        var description: String {
            switch self {
            case .frequencySpike: return "Unusually high email volume on a given day"
            case .unusualHour: return "Emails sent during late-night hours"
            case .newDomain: return "New sender domains appearing recently"
            case .toneShift: return "Significant sentiment change from a sender"
            case .largeAttachment: return "Emails with unusually many attachments"
            case .recipientAnomaly: return "Emails with unusually large recipient lists or unknown domains"
            }
        }
    }

    struct Anomaly: Identifiable {
        let id = UUID()
        let type: AnomalyType
        let severity: Double // 0.0 to 1.0
        let title: String
        let detail: String
        let affectedEmails: [UUID]
        let timestamp: Date?
    }

    // MARK: - Public Entry Point

    static func detectAnomalies(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        var anomalies: [Anomaly] = []

        anomalies.append(contentsOf: detectFrequencySpikes(in: emails))
        anomalies.append(contentsOf: detectUnusualHours(in: emails))
        anomalies.append(contentsOf: detectNewDomains(in: emails))
        anomalies.append(contentsOf: detectToneShifts(in: emails))
        anomalies.append(contentsOf: detectLargeAttachments(in: emails))
        anomalies.append(contentsOf: detectRecipientAnomalies(in: emails))

        return anomalies.sorted { $0.severity > $1.severity }
    }

    // MARK: - 1. Frequency Spike

    private static func detectFrequencySpikes(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        var dailyData: [String: (count: Int, ids: [UUID], date: Date)] = [:]

        for email in emails {
            guard let dateStr = email.headers["Date"],
                  let date = MBOXParser.parseDate(dateStr) else { continue }
            let dayKey = dayFormatter.string(from: date)
            var entry = dailyData[dayKey] ?? (count: 0, ids: [], date: date)
            entry.count += 1
            entry.ids.append(email.id)
            dailyData[dayKey] = entry
        }

        guard dailyData.count >= 8 else { return [] }

        let sortedDays = dailyData.keys.sorted()
        var anomalies: [Anomaly] = []

        for i in 7..<sortedDays.count {
            let windowStart = max(0, i - 7)
            let windowDays = sortedDays[windowStart..<i]
            let windowAvg = Double(windowDays.compactMap { dailyData[$0]?.count }.reduce(0, +)) / Double(windowDays.count)
            guard windowAvg > 0 else { continue }

            let dayKey = sortedDays[i]
            guard let dayData = dailyData[dayKey] else { continue }
            let ratio = Double(dayData.count) / windowAvg

            if ratio > 2.0 {
                let severity = min(1.0, (ratio - 2.0) / 4.0 + 0.3)
                anomalies.append(Anomaly(
                    type: .frequencySpike,
                    severity: severity,
                    title: "Volume spike on \(dayKey)",
                    detail: "\(dayData.count) emails received — \(String(format: "%.1f", ratio))x the 7-day rolling average of \(String(format: "%.1f", windowAvg)).",
                    affectedEmails: dayData.ids,
                    timestamp: dayData.date
                ))
            }
        }

        return anomalies
    }

    // MARK: - 2. Unusual Hour

    private static func detectUnusualHours(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        var lateNightIDs: [UUID] = []
        var latestTimestamp: Date?

        for email in emails {
            guard let dateStr = email.headers["Date"],
                  let date = MBOXParser.parseDate(dateStr) else { continue }
            let hour = Calendar.current.component(.hour, from: date)
            if hour >= 0 && hour < 5 {
                lateNightIDs.append(email.id)
                if latestTimestamp.map({ date > $0 }) ?? true {
                    latestTimestamp = date
                }
            }
        }

        guard lateNightIDs.count > 5 else { return [] }

        let severity = min(1.0, Double(lateNightIDs.count) / 30.0 + 0.3)
        return [Anomaly(
            type: .unusualHour,
            severity: severity,
            title: "\(lateNightIDs.count) late-night emails detected",
            detail: "Found \(lateNightIDs.count) emails sent between midnight and 5 AM, which may indicate automated activity or unusual behavior.",
            affectedEmails: lateNightIDs,
            timestamp: latestTimestamp
        )]
    }

    // MARK: - 3. New Domain

    private static func detectNewDomains(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        let sorted = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }

        guard sorted.count >= 10 else { return [] }

        let cutoffIndex = sorted.count - max(sorted.count / 10, 1)
        let historicalEmails = Array(sorted.prefix(cutoffIndex))
        let recentEmails = Array(sorted.suffix(from: cutoffIndex))

        var historicalDomains = Set<String>()
        for email in historicalEmails {
            if let domain = extractDomain(from: email.headers["From"] ?? "") {
                historicalDomains.insert(domain)
            }
        }

        var newDomainData: [String: [UUID]] = [:]
        var latestDate: Date?
        for email in recentEmails {
            if let domain = extractDomain(from: email.headers["From"] ?? ""),
               !historicalDomains.contains(domain) {
                newDomainData[domain, default: []].append(email.id)
                if let d = MBOXParser.parseDate(email.headers["Date"]) {
                    if latestDate.map({ d > $0 }) ?? true { latestDate = d }
                }
            }
        }

        var anomalies: [Anomaly] = []
        for (domain, ids) in newDomainData where ids.count >= 3 {
            let severity = min(1.0, Double(ids.count) / 15.0 + 0.3)
            anomalies.append(Anomaly(
                type: .newDomain,
                severity: severity,
                title: "New domain: \(domain)",
                detail: "\(ids.count) emails from \(domain) — a domain not seen in earlier messages.",
                affectedEmails: ids,
                timestamp: latestDate
            ))
        }

        return anomalies
    }

    // MARK: - 4. Tone Shift

    private static func detectToneShifts(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])

        let sorted = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }

        guard sorted.count >= 10 else { return [] }
        let midpoint = sorted.count / 2
        let firstHalf = Array(sorted.prefix(midpoint))
        let secondHalf = Array(sorted.suffix(from: midpoint))

        // Group by sender
        var senderFirstHalf: [String: [MBOXParser.RawEmail]] = [:]
        var senderSecondHalf: [String: [MBOXParser.RawEmail]] = [:]

        for email in firstHalf {
            let sender = (email.headers["From"] ?? "Unknown").lowercased()
            senderFirstHalf[sender, default: []].append(email)
        }
        for email in secondHalf {
            let sender = (email.headers["From"] ?? "Unknown").lowercased()
            senderSecondHalf[sender, default: []].append(email)
        }

        var anomalies: [Anomaly] = []

        for (sender, firstEmails) in senderFirstHalf {
            guard let secondEmails = senderSecondHalf[sender],
                  firstEmails.count >= 3 && secondEmails.count >= 3 else { continue }

            let firstAvg = averageSentiment(for: firstEmails, tagger: tagger)
            let secondAvg = averageSentiment(for: secondEmails, tagger: tagger)
            let drop = firstAvg - secondAvg

            if drop > 0.4 {
                let severity = min(1.0, drop / 0.8)
                let displaySender = firstEmails.first?.headers["From"] ?? sender
                let allIDs = (firstEmails + secondEmails).map(\.id)
                anomalies.append(Anomaly(
                    type: .toneShift,
                    severity: severity,
                    title: "Tone shift from \(displaySender)",
                    detail: "Sentiment dropped from \(String(format: "%.2f", firstAvg)) to \(String(format: "%.2f", secondAvg)) between first and second half of the archive.",
                    affectedEmails: allIDs,
                    timestamp: MBOXParser.parseDate(secondEmails.last?.headers["Date"])
                ))
            }
        }

        return anomalies
    }

    // MARK: - 5. Recipient Anomaly

    private static func detectRecipientAnomalies(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        var anomalies: [Anomaly] = []

        // Collect all known recipient domains
        var knownDomains = Set<String>()
        for email in emails {
            let allRecipients = (email.headers["To"] ?? "") + "," + (email.headers["Cc"] ?? "")
            for domain in extractAllDomains(from: allRecipients) {
                knownDomains.insert(domain)
            }
        }

        // Check large recipient lists and unknown domains
        for email in emails {
            let toField = email.headers["To"] ?? ""
            let ccField = email.headers["Cc"] ?? ""
            let allAddresses = (toField + "," + ccField)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains("@") }

            // Large recipient list
            if allAddresses.count > 10 {
                let severity = min(1.0, Double(allAddresses.count) / 50.0 + 0.4)
                anomalies.append(Anomaly(
                    type: .recipientAnomaly,
                    severity: severity,
                    title: "Large recipient list (\(allAddresses.count) recipients)",
                    detail: "Email \"\(email.headers["Subject"] ?? "(No Subject)")\" was sent to \(allAddresses.count) recipients.",
                    affectedEmails: [email.id],
                    timestamp: MBOXParser.parseDate(email.headers["Date"])
                ))
            }
        }

        return anomalies
    }

    // MARK: - 6. Large Attachment

    private static func detectLargeAttachments(in emails: [MBOXParser.RawEmail]) -> [Anomaly] {
        let counts = emails.map { $0.attachments.count }
        let nonZeroCounts = counts.filter { $0 > 0 }
        guard !nonZeroCounts.isEmpty else { return [] }

        let meanCount = Double(nonZeroCounts.reduce(0, +)) / Double(nonZeroCounts.count)
        let threshold = max(meanCount * 3.0, 3.0) // at least 3 attachments

        var anomalies: [Anomaly] = []
        for email in emails {
            let count = email.attachments.count
            guard Double(count) > threshold else { continue }

            let severity = min(1.0, Double(count) / (threshold * 3.0) + 0.3)
            anomalies.append(Anomaly(
                type: .largeAttachment,
                severity: severity,
                title: "\(count) attachments on one email",
                detail: "Email \"\(email.headers["Subject"] ?? "(No Subject)")\" has \(count) attachments — \(String(format: "%.1f", Double(count) / max(meanCount, 0.1)))x the archive average.",
                affectedEmails: [email.id],
                timestamp: MBOXParser.parseDate(email.headers["Date"])
            ))
        }

        return anomalies
    }

    // MARK: - Helpers

    private static func extractDomain(from header: String) -> String? {
        let address: String
        if let openAngle = header.firstIndex(of: "<"),
           let closeAngle = header.firstIndex(of: ">"),
           openAngle < closeAngle {
            let start = header.index(after: openAngle)
            address = String(header[start..<closeAngle]).trimmingCharacters(in: .whitespaces)
        } else if header.contains("@") {
            address = header.trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        guard let atIndex = address.firstIndex(of: "@") else { return nil }
        return String(address[address.index(after: atIndex)...]).lowercased()
    }

    private static func extractAllDomains(from recipientField: String) -> [String] {
        recipientField
            .components(separatedBy: ",")
            .compactMap { extractDomain(from: $0) }
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

    private static func averageSentiment(for emails: [MBOXParser.RawEmail], tagger: NLTagger) -> Double {
        var total = 0.0
        var count = 0
        for email in emails {
            let body = bodyText(for: email)
            guard !body.isEmpty else { continue }
            let text = String(body.prefix(2000))
            tagger.string = text
            let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
            total += Double(tag?.rawValue ?? "0") ?? 0
            count += 1
        }
        return count > 0 ? total / Double(count) : 0
    }
}
