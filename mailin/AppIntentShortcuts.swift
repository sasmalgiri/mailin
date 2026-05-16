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
    }
}
