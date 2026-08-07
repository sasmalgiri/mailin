import AppIntents
import Foundation

// MARK: - Archive Intent Support (SQLite v2 authority)

/// Shared archive access for the read-only intents below. Since the v2 cutover
/// the SQLite store is the ONLY archive authority — the legacy
/// `EmailPersistence` JSON is a bounded (≤5000-email) preview and must never be
/// read for archive truth. App Intents can run before the app has launched, so
/// every read first drives the idempotent activation gate (a fast no-op once
/// active) and fails gracefully with a clear message — never falling back to
/// the v1 store — when SQLite is not the confirmed authority.
private enum ArchiveIntentSupport {
    static let notReadyMessage = "mailin's email archive isn't ready yet. Open mailin once to finish preparing it, then try again."
    static let emptyMessage = "No emails imported yet. Open mailin and import an email archive first."

    /// Exact total archive count from a SQL aggregate, or nil when the SQLite
    /// authority could not be activated (caller returns `notReadyMessage`).
    static func activatedTotal() async -> Int? {
        guard await StorageActivationCoordinator.shared.activate() == .active else { return nil }
        return try? await ArchiveAggregateService.shared.total()
    }

    /// The `limit` most recent full emails via bounded keyset pages. `limit`
    /// is a hard cap (callers pass ≤500) — the corpus is never materialized.
    static func recentEmails(limit: Int) async -> [MBOXParser.RawEmail] {
        guard limit > 0 else { return [] }
        var acc: [MBOXParser.RawEmail] = []
        let stream = await ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: min(limit, 200))
        do {
            for try await batch in stream {
                acc.append(contentsOf: batch)
                if acc.count >= limit { break }
            }
        } catch { }
        return Array(acc.prefix(limit))
    }
}

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
        // Bounded FTS5-backed retrieval (was the in-RAM EmailSearchIndex).
        let results = (try? await ArchiveRetrievalService.shared.retrieve(query, limit: 10)) ?? []
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
        // Exact total + date range come from SQL aggregates over the SQLite v2
        // authority — never from the truncated v1 JSON preview.
        guard let total = await ArchiveIntentSupport.activatedTotal() else {
            return .result(value: ArchiveIntentSupport.notReadyMessage)
        }
        guard total > 0 else {
            return .result(value: ArchiveIntentSupport.emptyMessage)
        }
        let snapshot = try? await ArchiveAggregateService.shared.snapshot()
        let dateRange: String
        if let first = snapshot?.minDate, let last = snapshot?.maxDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            dateRange = "\(formatter.string(from: first)) to \(formatter.string(from: last))"
        } else {
            dateRange = "unknown"
        }
        // Sent/received + unique subjects over a bounded recent sample (cap:
        // 500). The v2 store does not persist the parse-time messageType, so
        // we re-apply the parser's rule (From contains the configured sender —
        // see MBOXParser) on the sample instead of loading the whole corpus.
        let senderEmail = UserDefaults.standard.string(forKey: "defaultSenderEmail") ?? ""
        let sample = await ArchiveIntentSupport.recentEmails(limit: 500)
        let normalizedSender = senderEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = normalizedSender.isEmpty
            ? 0
            : sample.filter { ($0.headers["From"] ?? "").lowercased().contains(normalizedSender) }.count
        let received = sample.count - sent
        let uniqueSubjects = Set(sample.compactMap { $0.headers["Subject"] }).count
        let senderInfo = senderEmail.isEmpty ? "" : " (sender: \(senderEmail))"
        return .result(value: "\(total) emails\(senderInfo): \(sent) sent, \(received) received, \(uniqueSubjects) unique subjects in the \(sample.count) most recent. Date range: \(dateRange).")
    }
}

// MARK: - 5. Analyze Sentiment Intent

struct AnalyzeSentimentIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze Email Sentiment"
    static var description: IntentDescription = "Analyzes the emotional tone of imported emails"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let total = await ArchiveIntentSupport.activatedTotal() else {
            return .result(value: ArchiveIntentSupport.notReadyMessage)
        }
        guard total > 0 else {
            return .result(value: ArchiveIntentSupport.emptyMessage)
        }
        // Analyze a bounded recent sample (cap: 200) to keep Siri response fast
        let sample = await ArchiveIntentSupport.recentEmails(limit: 200)
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
        guard let total = await ArchiveIntentSupport.activatedTotal() else {
            return .result(value: ArchiveIntentSupport.notReadyMessage)
        }
        guard total > 0 else {
            return .result(value: ArchiveIntentSupport.emptyMessage)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard FoundationModelEngine.isAvailable else {
                return .result(value: "Apple Intelligence is not available on this device.")
            }
            // Bounded evidence (cap: 20): FTS5-ranked retrieval for the
            // question; falls back to the 20 most recent when nothing matches.
            var evidence = ((try? await ArchiveRetrievalService.shared.retrieve(question, limit: 20)) ?? []).map(\.email)
            if evidence.isEmpty {
                evidence = await ArchiveIntentSupport.recentEmails(limit: 20)
            }
            let result = try await FoundationModelEngine.synthesizeFromNLPResults(
                query: question,
                retrievedEmails: evidence,
                nlpAnalysis: "",
                allEmailCount: total,
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
        guard let total = await ArchiveIntentSupport.activatedTotal() else {
            return .result(value: ArchiveIntentSupport.notReadyMessage)
        }
        guard total > 0 else {
            return .result(value: ArchiveIntentSupport.emptyMessage)
        }

        // Bounded scan of the most recent emails (cap: 500, same as before).
        let sample = await ArchiveIntentSupport.recentEmails(limit: 500)
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
        guard let total = await ArchiveIntentSupport.activatedTotal() else {
            return .result(value: ArchiveIntentSupport.notReadyMessage)
        }
        guard total > 0 else {
            return .result(value: ArchiveIntentSupport.emptyMessage)
        }

        // Topics/mood from a bounded recent sample (cap: 300, same as before);
        // top senders from an exact whole-archive SQL aggregate.
        let sample = await ArchiveIntentSupport.recentEmails(limit: 300)
        let topics = EmailNLPEngine.extractTopics(from: sample, limit: 5)
        let sentiment = EmailNLPEngine.averageSentiment(of: sample)
        let topSenders = (try? await ArchiveAggregateService.shared.topSenders(limit: 5)) ?? []

        var digest = "Digest for \(total) emails:\n\n"
        digest += "Top topics: \(topics.map(\.word).joined(separator: ", "))\n"
        digest += "Overall mood: \(sentiment.label) (score: \(String(format: "%.2f", sentiment.average)))\n"
        digest += "Top senders: \(topSenders.map { "\($0.value.prefix(30)) (\($0.count))" }.joined(separator: ", "))\n"
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
