import AppIntents
import Foundation

// MARK: - 1. Open mailin Intent

struct OpenMailinIntent: AppIntent {
    static var title: LocalizedStringResource = "Open mailin"
    static var description: IntentDescription = "Opens the mailin email archive analyzer"

    func perform() async throws -> some IntentResult {
        return .result()
    }

    static var openAppWhenRun: Bool = true
}

// MARK: - 2. Import Email Archive Intent

struct ImportArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Import Email Archive"
    static var description: IntentDescription = "Opens mailin to import an email archive file"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .triggerFileImportFromShortcut, object: nil)
        }
        return .result()
    }

    static var openAppWhenRun: Bool = true
}

// MARK: - 3. Search Emails Intent

struct SearchEmailsIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Emails in mailin"
    static var description: IntentDescription = "Search through imported email archives"

    @Parameter(title: "Search Query")
    var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let searchTerms = query.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { $0.count >= 2 }
        let results = EmailSearchIndex.shared.search(terms: searchTerms, limit: 10)
        let count = results.count
        return .result(value: "Found \(count) emails matching '\(query)'")
    }

    static var openAppWhenRun: Bool = true
}

// MARK: - 4. Get Email Stats Intent

struct GetEmailStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Email Statistics"
    static var description: IntentDescription = "Returns statistics about the current email archive"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (emails, senderEmail) = EmailPersistence.load()
        guard !emails.isEmpty else {
            return .result(value: "No emails imported yet. Open mailin and import an email archive first.")
        }
        let total = emails.count
        let sent = emails.filter { $0.messageType == "sent" }.count
        let received = emails.filter { $0.messageType == "received" }.count
        let uniqueSubjects = Set(emails.compactMap { $0.headers["Subject"] }).count
        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let dateRange: String
        if let first = dates.first, let last = dates.last {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            dateRange = "\(formatter.string(from: first)) to \(formatter.string(from: last))"
        } else {
            dateRange = "unknown"
        }
        let senderInfo = senderEmail.isEmpty ? "" : " (sender: \(senderEmail))"
        return .result(value: "\(total) emails\(senderInfo): \(sent) sent, \(received) received, \(uniqueSubjects) unique subjects. Date range: \(dateRange).")
    }
}

// MARK: - 5. Analyze Sentiment Intent

struct AnalyzeSentimentIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze Email Sentiment"
    static var description: IntentDescription = "Analyzes the emotional tone of imported emails"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (emails, _) = EmailPersistence.load()
        guard !emails.isEmpty else {
            return .result(value: "No emails imported yet. Open mailin and import an email archive first.")
        }
        // Analyze a sample to keep Siri response fast
        let sample = Array(emails.prefix(200))
        let (average, label, positive, negative, neutral) = EmailNLPEngine.averageSentiment(of: sample)
        let analyzed = sample.count
        let scoreFormatted = String(format: "%.2f", average)
        return .result(value: "Analyzed \(analyzed) emails: overall \(label) (score: \(scoreFormatted)). \(positive) positive, \(negative) negative, \(neutral) neutral.")
    }

    static var openAppWhenRun: Bool = true
}

// MARK: - 6. Ask AI About Emails Intent (v4.3.2)

struct AskAIAboutEmailsIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask AI About Emails"
    static var description: IntentDescription = "Ask mailin's AI assistant a question about your email archive"

    @Parameter(title: "Question")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (emails, _) = EmailPersistence.load()
        guard !emails.isEmpty else {
            return .result(value: "No emails imported yet. Open mailin and import an email archive first.")
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard FoundationModelEngine.isAvailable else {
                return .result(value: "Apple Intelligence is not available on this device.")
            }
            let result = try await FoundationModelEngine.synthesizeFromNLPResults(
                query: question,
                retrievedEmails: Array(emails.prefix(20)),
                nlpAnalysis: "",
                allEmailCount: emails.count,
                onUpdate: { _ in }
            )
            let trimmed = String(result.prefix(500))
            return .result(value: trimmed)
        }
        #endif
        return .result(value: "AI features require macOS 26 or iOS 26 with Apple Intelligence.")
    }

    static var openAppWhenRun: Bool = false
}

// MARK: - 7. Get Security Report Intent (v4.3.2)

struct GetSecurityReportIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Email Security Report"
    static var description: IntentDescription = "Run a security scan on your email archive and get a summary"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (emails, _) = EmailPersistence.load()
        guard !emails.isEmpty else {
            return .result(value: "No emails imported yet. Open mailin and import an email archive first.")
        }

        let sample = Array(emails.prefix(500))
        let phishingFlags = EmailNLPEngine.detectPhishing(in: sample)
        let highRisk = phishingFlags.filter { $0.riskLevel == .high }.count
        let medRisk = phishingFlags.filter { $0.riskLevel == .medium }.count
        let pii = EmailNLPEngine.piiSummary(in: sample)
        let anomalies = AnomalyDetectionEngine.detectAnomalies(in: sample)

        var report = "Security scan of \(sample.count) emails:\n"
        report += "Phishing risk: \(highRisk) high-risk, \(medRisk) medium-risk\n"

        let piiCount = pii.values.reduce(0, +)
        if piiCount > 0 {
            let piiTypes = pii.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ")
            report += "PII detected: \(piiTypes)\n"
        } else {
            report += "No PII detected\n"
        }

        if !anomalies.isEmpty {
            report += "Anomalies found: \(anomalies.count) (\(anomalies.prefix(3).map(\.type.rawValue).joined(separator: "; ")))"
        } else {
            report += "No anomalies detected"
        }

        return .result(value: String(report.prefix(500)))
    }

    static var openAppWhenRun: Bool = false
}

// MARK: - 8. Get AI Digest Intent (v4.3.2)

struct GetDigestIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Email Digest"
    static var description: IntentDescription = "Generate an AI-powered digest summary of your email archive"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (emails, _) = EmailPersistence.load()
        guard !emails.isEmpty else {
            return .result(value: "No emails imported yet. Open mailin and import an email archive first.")
        }

        let sample = Array(emails.prefix(300))
        let topics = EmailNLPEngine.extractTopics(from: sample, limit: 5)
        let sentiment = EmailNLPEngine.averageSentiment(of: sample)
        let topSenders = Dictionary(grouping: sample, by: { $0.headers["From"] ?? "Unknown" })
            .sorted { $0.value.count > $1.value.count }
            .prefix(5)

        var digest = "Digest for \(emails.count) emails:\n\n"
        digest += "Top topics: \(topics.map(\.word).joined(separator: ", "))\n"
        digest += "Overall mood: \(sentiment.label) (score: \(String(format: "%.2f", sentiment.average)))\n"
        digest += "Top senders: \(topSenders.map { "\($0.key.prefix(30)) (\($0.value.count))" }.joined(separator: ", "))\n"
        digest += "Positive: \(sentiment.positive), Negative: \(sentiment.negative), Neutral: \(sentiment.neutral)"

        return .result(value: String(digest.prefix(500)))
    }

    static var openAppWhenRun: Bool = false
}

// MARK: - App Shortcuts Provider

struct MailinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMailinIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)"
            ],
            shortTitle: "Open mailin",
            systemImageName: "envelope.open"
        )

        AppShortcut(
            intent: ImportArchiveIntent(),
            phrases: [
                "Import emails in \(.applicationName)",
                "Open email archive in \(.applicationName)"
            ],
            shortTitle: "Import Archive",
            systemImageName: "square.and.arrow.down"
        )

        AppShortcut(
            intent: SearchEmailsIntent(),
            phrases: [
                "Search emails in \(.applicationName)",
                "Find emails in \(.applicationName)"
            ],
            shortTitle: "Search Emails",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: AskAIAboutEmailsIntent(),
            phrases: [
                "Ask \(.applicationName) about my emails",
                "Ask \(.applicationName) a question",
                "What does \(.applicationName) think about my emails"
            ],
            shortTitle: "Ask AI",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: GetSecurityReportIntent(),
            phrases: [
                "Get security report from \(.applicationName)",
                "Check email security in \(.applicationName)",
                "Scan emails for threats in \(.applicationName)"
            ],
            shortTitle: "Security Report",
            systemImageName: "shield.checkered"
        )

        AppShortcut(
            intent: GetDigestIntent(),
            phrases: [
                "Get email digest from \(.applicationName)",
                "Summarize my emails in \(.applicationName)",
                "Email summary from \(.applicationName)"
            ],
            shortTitle: "Email Digest",
            systemImageName: "text.document"
        )
    }
}
