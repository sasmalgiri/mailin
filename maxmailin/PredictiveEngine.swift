import Foundation
import NaturalLanguage

// MARK: - Predictive Engine (v3.7.1)

struct PredictiveEngine {

    // MARK: - Prediction Types

    enum UrgencyLevel: String, CaseIterable, Comparable {
        case critical = "Critical"
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        case none = "None"

        private var rank: Int {
            switch self {
            case .critical: return 4
            case .high: return 3
            case .medium: return 2
            case .low: return 1
            case .none: return 0
            }
        }

        static func < (lhs: UrgencyLevel, rhs: UrgencyLevel) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    enum ConversationOutcome: String {
        case reachingConsensus = "Reaching Consensus"
        case atRiskOfConflict = "At Risk of Conflict"
        case stalled = "Stalled"
        case activeDiscussion = "Active Discussion"
        case resolved = "Resolved"
        case unknown = "Unknown"
    }

    struct UrgencyPrediction: Identifiable {
        let id = UUID()
        let email: MBOXParser.RawEmail
        let urgency: UrgencyLevel
        let reason: String
        let score: Double
    }

    struct ThreadPrediction: Identifiable {
        let id = UUID()
        let subject: String
        let participants: [String]
        let outcome: ConversationOutcome
        let confidence: Double
        let sentimentTrajectory: String
        let detail: String
    }

    struct SecurityForecast {
        let riskLevel: String
        let phishingTrend: String
        let piiExposureTrend: String
        let recommendations: [String]
    }

    struct PredictionSummary {
        let urgentEmails: [UrgencyPrediction]
        let threadPredictions: [ThreadPrediction]
        let securityForecast: SecurityForecast
    }

    // MARK: - Full Predictive Analysis

    static func analyze(emails: [MBOXParser.RawEmail]) -> PredictionSummary {
        let urgency = predictUrgency(emails: emails)
        let threads = predictThreadOutcomes(emails: emails)
        let security = forecastSecurityRisk(emails: emails)
        return PredictionSummary(
            urgentEmails: urgency,
            threadPredictions: threads,
            securityForecast: security
        )
    }

    // MARK: - Response Urgency Prediction

    static func predictUrgency(emails: [MBOXParser.RawEmail]) -> [UrgencyPrediction] {
        var predictions: [UrgencyPrediction] = []

        for email in emails {
            var score = 0.0
            var reasons: [String] = []
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let body = email.plainBody.lowercased()
            let combined = subject + " " + body

            // Time-based urgency keywords
            let criticalKeywords = ["urgent", "asap", "immediately", "emergency", "critical", "deadline today"]
            let highKeywords = ["time-sensitive", "by end of day", "eod", "before tomorrow", "action required",
                                "action needed", "please respond", "waiting for your", "overdue"]
            let mediumKeywords = ["follow up", "follow-up", "reminder", "fyi", "when you get a chance",
                                  "could you", "would you", "need your input"]

            for kw in criticalKeywords where combined.contains(kw) {
                score += 0.3
                reasons.append("Contains '\(kw)'")
            }
            for kw in highKeywords where combined.contains(kw) {
                score += 0.2
                reasons.append("Contains '\(kw)'")
            }
            for kw in mediumKeywords where combined.contains(kw) {
                score += 0.1
                reasons.append("Contains '\(kw)'")
            }

            // Question detection
            let questionCount = combined.components(separatedBy: "?").count - 1
            if questionCount >= 2 {
                score += 0.15
                reasons.append("\(questionCount) questions asked")
            }

            // Exclamation marks (urgency signal)
            let exclamationCount = subject.filter { $0 == "!" }.count
            if exclamationCount >= 2 {
                score += 0.1
                reasons.append("Multiple exclamation marks")
            }

            // ALL CAPS subject
            let upperRatio = subject.isEmpty ? 0.0 :
                Double(subject.filter(\.isUppercase).count) / Double(max(1, subject.filter(\.isLetter).count))
            if upperRatio > 0.6 && subject.count > 5 {
                score += 0.1
                reasons.append("Subject is mostly uppercase")
            }

            // Recency boost — more recent emails are more urgent
            if let dateStr = email.headers["Date"], let date = MBOXParser.parseDate(dateStr) {
                let daysSince = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 999
                if daysSince <= 1 {
                    score += 0.1
                    reasons.append("Received today/yesterday")
                } else if daysSince <= 3 {
                    score += 0.05
                }
            }

            // Sentiment — negative sentiment increases urgency
            let sentiments = EmailNLPEngine.analyzeSentiment(of: [email])
            if let s = sentiments.first, s.score < -0.3 {
                score += 0.1
                reasons.append("Negative sentiment (\(String(format: "%.2f", s.score)))")
            }

            guard score > 0.05 else { continue }

            let urgency: UrgencyLevel
            if score >= 0.5 { urgency = .critical }
            else if score >= 0.35 { urgency = .high }
            else if score >= 0.2 { urgency = .medium }
            else { urgency = .low }

            predictions.append(UrgencyPrediction(
                email: email,
                urgency: urgency,
                reason: reasons.prefix(3).joined(separator: "; "),
                score: min(score, 1.0)
            ))
        }

        return predictions.sorted { $0.score > $1.score }
    }

    // MARK: - Thread Outcome Prediction

    static func predictThreadOutcomes(emails: [MBOXParser.RawEmail]) -> [ThreadPrediction] {
        let threads = ThreadGrouper.group(emails).filter { $0.count >= 3 }
        guard !threads.isEmpty else { return [] }

        var predictions: [ThreadPrediction] = []

        for thread in threads.prefix(20) {
            let trend = EmailNLPEngine.threadSentimentTrend(thread.members)
            let points = trend.points
            guard points.count >= 2 else { continue }

            let recentSentiments = points.suffix(max(1, points.count / 2)).map(\.sentiment)
            let olderSentiments = points.prefix(max(1, points.count / 2)).map(\.sentiment)
            let recentAvg = recentSentiments.reduce(0, +) / Double(max(1, recentSentiments.count))
            let olderAvg = olderSentiments.reduce(0, +) / Double(max(1, olderSentiments.count))
            let sentimentDelta = recentAvg - olderAvg

            // Response frequency — are people still engaged?
            let dates = thread.members.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            let lastMessageAge: Int
            if let last = dates.last {
                lastMessageAge = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 999
            } else {
                lastMessageAge = 999
            }

            // Participant engagement — are all participants still responding?
            let allParticipants = Set(thread.members.compactMap { $0.headers["From"]?.lowercased() })
            let recentParticipants = Set(thread.members.suffix(max(1, thread.count / 2)).compactMap { $0.headers["From"]?.lowercased() })
            let engagementRatio = allParticipants.isEmpty ? 0 : Double(recentParticipants.count) / Double(allParticipants.count)

            // Outcome prediction
            let outcome: ConversationOutcome
            let confidence: Double
            var detail = ""

            if lastMessageAge > 14 {
                outcome = .resolved
                confidence = 0.6
                detail = "No activity for \(lastMessageAge) days — likely resolved or abandoned"
            } else if lastMessageAge > 7 && engagementRatio < 0.5 {
                outcome = .stalled
                confidence = 0.7
                detail = "Reduced participation (\(Int(engagementRatio * 100))% of participants active recently)"
            } else if sentimentDelta < -0.3 && recentAvg < -0.2 {
                outcome = .atRiskOfConflict
                confidence = min(0.5 + abs(sentimentDelta), 0.9)
                detail = "Sentiment declining sharply: \(String(format: "%.2f", olderAvg)) \u{2192} \(String(format: "%.2f", recentAvg))"
            } else if sentimentDelta > 0.2 && recentAvg > 0.1 {
                outcome = .reachingConsensus
                confidence = min(0.5 + sentimentDelta, 0.9)
                detail = "Sentiment improving: \(String(format: "%.2f", olderAvg)) \u{2192} \(String(format: "%.2f", recentAvg))"
            } else {
                outcome = .activeDiscussion
                confidence = 0.5
                detail = "\(thread.count) messages, \(allParticipants.count) participants, sentiment stable"
            }

            let trajectory: String
            if sentimentDelta > 0.15 { trajectory = "improving" }
            else if sentimentDelta < -0.15 { trajectory = "declining" }
            else { trajectory = "stable" }

            predictions.append(ThreadPrediction(
                subject: thread.subject,
                participants: Array(allParticipants.prefix(5)),
                outcome: outcome,
                confidence: confidence,
                sentimentTrajectory: trajectory,
                detail: detail
            ))
        }

        return predictions.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Security Risk Forecasting

    static func forecastSecurityRisk(emails: [MBOXParser.RawEmail]) -> SecurityForecast {
        let phishing = EmailNLPEngine.detectPhishing(in: emails)
        let pii = EmailNLPEngine.detectPII(in: emails)
        let anomalies = AnomalyDetectionEngine.detectAnomalies(in: emails)

        let highPhishing = phishing.filter { $0.riskLevel == .high }.count
        let medPhishing = phishing.filter { $0.riskLevel == .medium }.count
        let phishingRate = emails.isEmpty ? 0.0 : Double(highPhishing + medPhishing) / Double(emails.count)

        let phishingTrend: String
        if phishingRate > 0.1 { phishingTrend = "High — \(Int(phishingRate * 100))% of emails flagged" }
        else if phishingRate > 0.03 { phishingTrend = "Moderate — \(highPhishing) high-risk, \(medPhishing) medium-risk" }
        else if highPhishing > 0 { phishingTrend = "Low but present — \(highPhishing) high-risk email(s)" }
        else { phishingTrend = "Clean — no phishing detected" }

        let piiCount = pii.count
        let criticalPII = pii.filter { $0.contextualRiskScore > 7.0 }.count
        let piiTrend: String
        if criticalPII > 0 { piiTrend = "Critical — \(criticalPII) high-risk PII exposures (SSN, credit card, etc.)" }
        else if piiCount > 5 { piiTrend = "Elevated — \(piiCount) PII findings across archive" }
        else if piiCount > 0 { piiTrend = "Low — \(piiCount) minor PII finding(s)" }
        else { piiTrend = "Clean — no PII detected" }

        let securityAnomalies = anomalies.filter { $0.type == .newDomain || $0.type == .recipientAnomaly }
        let riskLevel: String
        if highPhishing >= 3 || criticalPII >= 2 {
            riskLevel = "High"
        } else if highPhishing >= 1 || medPhishing >= 5 || criticalPII >= 1 || securityAnomalies.count >= 3 {
            riskLevel = "Medium"
        } else if medPhishing >= 1 || piiCount > 0 || !securityAnomalies.isEmpty {
            riskLevel = "Low"
        } else {
            riskLevel = "Minimal"
        }

        var recommendations: [String] = []
        if highPhishing > 0 {
            recommendations.append("Review \(highPhishing) high-risk phishing email(s) immediately")
        }
        if criticalPII > 0 {
            recommendations.append("Address \(criticalPII) critical PII exposure(s) — potential compliance risk")
        }
        if !securityAnomalies.isEmpty {
            recommendations.append("Investigate \(securityAnomalies.count) security anomalies (new domains, unusual recipients)")
        }
        if phishingRate > 0.05 {
            recommendations.append("Consider sender verification training — \(Int(phishingRate * 100))% phishing rate is elevated")
        }
        if recommendations.isEmpty {
            recommendations.append("No immediate actions required — archive appears clean")
        }

        return SecurityForecast(
            riskLevel: riskLevel,
            phishingTrend: phishingTrend,
            piiExposureTrend: piiTrend,
            recommendations: recommendations
        )
    }

    // MARK: - Text Summary for AI Integration

    static func summaryForAI(emails: [MBOXParser.RawEmail]) -> String {
        let summary = analyze(emails: emails)

        var text = "PREDICTIVE ANALYSIS:\n"

        let urgent = summary.urgentEmails.filter { $0.urgency >= .medium }
        if !urgent.isEmpty {
            text += "URGENT (\(urgent.count)):\n"
            for u in urgent.prefix(5) {
                let subj = u.email.headers["Subject"] ?? "?"
                text += "  [\(u.urgency.rawValue)] \"\(subj)\" — \(u.reason)\n"
            }
        }

        let notable = summary.threadPredictions.filter { $0.outcome == .atRiskOfConflict || $0.outcome == .stalled }
        if !notable.isEmpty {
            text += "THREAD ALERTS:\n"
            for t in notable.prefix(5) {
                text += "  [\(t.outcome.rawValue)] \"\(t.subject)\" — \(t.detail)\n"
            }
        }

        text += "SECURITY: \(summary.securityForecast.riskLevel) risk — \(summary.securityForecast.phishingTrend)\n"

        return text
    }

    // MARK: - Digest Items

    static func digestItems(emails: [MBOXParser.RawEmail]) -> [(title: String, detail: String, priority: Int)] {
        let summary = analyze(emails: emails)
        var items: [(title: String, detail: String, priority: Int)] = []

        let critical = summary.urgentEmails.filter { $0.urgency >= .high }
        if !critical.isEmpty {
            items.append((
                title: "\(critical.count) Email\(critical.count == 1 ? "" : "s") Need Urgent Response",
                detail: critical.prefix(3).map { $0.email.headers["Subject"] ?? "?" }.joined(separator: ", "),
                priority: 2
            ))
        }

        let atRisk = summary.threadPredictions.filter { $0.outcome == .atRiskOfConflict }
        for thread in atRisk.prefix(2) {
            items.append((
                title: "Thread At Risk: \"\(thread.subject)\"",
                detail: thread.detail,
                priority: 2
            ))
        }

        let stalled = summary.threadPredictions.filter { $0.outcome == .stalled }
        if !stalled.isEmpty {
            items.append((
                title: "\(stalled.count) Stalled Conversation\(stalled.count == 1 ? "" : "s")",
                detail: stalled.prefix(3).map(\.subject).joined(separator: ", "),
                priority: 1
            ))
        }

        let consensus = summary.threadPredictions.filter { $0.outcome == .reachingConsensus }
        for thread in consensus.prefix(2) {
            items.append((
                title: "Consensus Forming: \"\(thread.subject)\"",
                detail: thread.detail,
                priority: 0
            ))
        }

        if summary.securityForecast.riskLevel == "High" || summary.securityForecast.riskLevel == "Medium" {
            items.append((
                title: "Security Risk: \(summary.securityForecast.riskLevel)",
                detail: summary.securityForecast.recommendations.first ?? "",
                priority: summary.securityForecast.riskLevel == "High" ? 2 : 1
            ))
        }

        return items.sorted { $0.priority > $1.priority }
    }
}

// MARK: - Bounded, store-driven analysis (v2 engine cutover)
//
// The static functions above operate on an in-memory `[RawEmail]` corpus — the
// v1 pattern where resident memory scaled with archive size. These entry points
// instead stream the most-recent working set from the activated SQLite store in
// bounded keyset pages, so predictive analysis of a 10M-email archive never
// holds more than `cap` emails resident.
//
// This is sound *because* every prediction here is recency-weighted: urgency
// boosts recent mail, thread outcomes look at the latest activity, and the
// security forecast reflects the current posture. The most-recent window is
// therefore both the correct analytical basis and a hard memory bound.

extension PredictiveEngine {

    /// Default resident cap for the recency-weighted working set.
    static let defaultWorkingSetCap = 5000

    /// Full predictive analysis over a bounded, most-recent working set streamed
    /// from the store. Memory is bounded by `cap` regardless of archive size.
    static func analyze(
        from service: ArchiveDataService,
        query: EmailQuery = .all,
        cap: Int = defaultWorkingSetCap,
        batchSize: Int = 200
    ) async throws -> PredictionSummary {
        let working = try await recentWorkingSet(from: service, query: query, cap: cap, batchSize: batchSize)
        // This function is nonisolated async, so the CPU-heavy `analyze` runs on
        // a background executor rather than the MainActor.
        return analyze(emails: working)
    }

    /// Text summary for AI integration, over the bounded working set.
    static func summaryForAI(
        from service: ArchiveDataService,
        query: EmailQuery = .all,
        cap: Int = defaultWorkingSetCap
    ) async throws -> String {
        let working = try await recentWorkingSet(from: service, query: query, cap: cap)
        return summaryForAI(emails: working)
    }

    /// Digest items over the bounded working set.
    static func digestItems(
        from service: ArchiveDataService,
        query: EmailQuery = .all,
        cap: Int = defaultWorkingSetCap
    ) async throws -> [(title: String, detail: String, priority: Int)] {
        let working = try await recentWorkingSet(from: service, query: query, cap: cap)
        return digestItems(emails: working)
    }

    /// Collect up to `cap` most-recent full emails via bounded keyset streaming.
    /// Beyond the accumulator, only one `batchSize` page is transiently resident,
    /// and iteration stops as soon as `cap` is reached — the rest of the archive
    /// is never read.
    static func recentWorkingSet(
        from service: ArchiveDataService,
        query: EmailQuery = .all,
        cap: Int = defaultWorkingSetCap,
        batchSize: Int = 200
    ) async throws -> [MBOXParser.RawEmail] {
        guard cap > 0 else { return [] }
        var working: [MBOXParser.RawEmail] = []
        working.reserveCapacity(min(cap, 1024))
        let stream = await service.streamFullEmails(query: query, batchSize: min(batchSize, cap))
        for try await batch in stream {
            working.append(contentsOf: batch)
            if working.count >= cap {
                return Array(working.prefix(cap))
            }
        }
        return working
    }
}
