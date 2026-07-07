import Foundation
import NaturalLanguage

struct SecurityAnalysisFeatures {

    // MARK: - Types

    struct ThreatCorrelation: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let compositeScore: Double
        let signals: [ThreatSignal]
        let threatLevel: ThreatLevel
        let attackVector: AttackVector?

        enum ThreatLevel: String, CaseIterable, Comparable {
            case critical = "Critical"
            case high = "High"
            case medium = "Medium"
            case low = "Low"
            case clean = "Clean"

            static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool {
                let order: [ThreatLevel] = [.clean, .low, .medium, .high, .critical]
                return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
            }
        }

        enum AttackVector: String {
            case phishing = "Phishing"
            case spearPhishing = "Spear Phishing"
            case businessEmailCompromise = "Business Email Compromise"
            case malwareDelivery = "Malware Delivery"
            case credentialHarvesting = "Credential Harvesting"
            case socialEngineering = "Social Engineering"
            case spoofing = "Spoofing"
        }
    }

    struct ThreatSignal {
        let category: SignalCategory
        let severity: Double
        let detail: String

        enum SignalCategory: String {
            case authentication = "Authentication"
            case content = "Content"
            case behavioral = "Behavioral"
            case technical = "Technical"
            case reputation = "Reputation"
        }
    }

    struct DomainReputation: Identifiable {
        let id: String
        let domain: String
        let score: Double
        let emailCount: Int
        let authenticationRate: Double
        let phishingRate: Double
        let firstSeen: Date?
        let lastSeen: Date?
        let riskFactors: [String]
        let category: DomainCategory

        enum DomainCategory: String {
            case trusted = "Trusted"
            case known = "Known"
            case suspicious = "Suspicious"
            case malicious = "Malicious"
            case newUnverified = "New/Unverified"
        }
    }

    struct CompromiseIndicator: Identifiable {
        let id: UUID
        let accountEmail: String
        let confidence: Double
        let indicators: [String]
        let affectedEmails: [MBOXParser.RawEmail]
        let timeWindow: (first: Date, last: Date)?
    }

    struct SecurityEvent: Identifiable {
        let id: UUID
        let timestamp: Date
        let eventType: SecurityEventType
        let severity: Double
        let summary: String
        let affectedEmails: [UUID]

        enum SecurityEventType: String, CaseIterable {
            case phishingCampaign = "Phishing Campaign"
            case authFailure = "Authentication Failure"
            case newThreatDomain = "New Threat Domain"
            case accountAnomaly = "Account Anomaly"
            case dataExfiltration = "Potential Data Exfiltration"
            case spoofingAttempt = "Spoofing Attempt"
            case bulkSuspicious = "Bulk Suspicious Activity"
        }
    }

    struct AuthenticationHealth {
        let domain: String
        let totalEmails: Int
        let spfPass: Int
        let spfFail: Int
        let dkimPass: Int
        let dkimFail: Int
        let dmarcPass: Int
        let dmarcFail: Int
        let overallScore: Double
    }

    // MARK: - Threat Correlation

    static func correlateThreatSignals(
        emails: [MBOXParser.RawEmail],
        phishingFlags: [EmailNLPEngine.PhishingFlag] = [],
        anomalies: [AnomalyDetectionEngine.Anomaly] = []
    ) -> [ThreatCorrelation] {
        let phishingByID = Dictionary(grouping: phishingFlags, by: { $0.email.id })
        let anomalyEmailIDs = Set(anomalies.flatMap { $0.affectedEmails })

        return emails.compactMap { email -> ThreatCorrelation? in
            var signals: [ThreatSignal] = []
            var totalScore: Double = 0

            let authResult = EmailNLPEngine.parseAuthenticationResults(email.headers)
            if authResult.spfResult == .fail || authResult.spfResult == .softfail {
                let sev = authResult.spfResult == .fail ? 0.8 : 0.5
                signals.append(ThreatSignal(category: .authentication, severity: sev, detail: "SPF \(authResult.spfResult.rawValue) for \(authResult.spfDomain ?? "unknown")"))
                totalScore += sev * 2
            }
            if authResult.dkimResult == .fail {
                signals.append(ThreatSignal(category: .authentication, severity: 0.7, detail: "DKIM verification failed"))
                totalScore += 1.4
            }
            if authResult.dmarcResult == .fail {
                signals.append(ThreatSignal(category: .authentication, severity: 0.9, detail: "DMARC policy violation"))
                totalScore += 1.8
            }

            if let flags = phishingByID[email.id] {
                for flag in flags {
                    let sev: Double = flag.riskLevel == .high ? 0.9 : (flag.riskLevel == .medium ? 0.6 : 0.3)
                    for reason in flag.reasons.prefix(3) {
                        signals.append(ThreatSignal(category: .content, severity: sev, detail: reason))
                    }
                    totalScore += sev * Double(flag.reasons.count)
                }
            }

            if anomalyEmailIDs.contains(email.id) {
                let relevantAnomalies = anomalies.filter { $0.affectedEmails.contains(email.id) }
                for anomaly in relevantAnomalies {
                    signals.append(ThreatSignal(category: .behavioral, severity: anomaly.severity, detail: anomaly.title))
                    totalScore += anomaly.severity
                }
            }

            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
            let attachments = email.attachments
            let dangerousExtensions = ["exe", "bat", "cmd", "scr", "pif", "js", "vbs", "wsf", "ps1", "msi", "dll", "com"]
            for att in attachments {
                let ext = (att.filename as NSString).pathExtension.lowercased()
                if dangerousExtensions.contains(ext) {
                    signals.append(ThreatSignal(category: .technical, severity: 0.9, detail: "Dangerous attachment type: .\(ext)"))
                    totalScore += 2.0
                }
            }

            if body.contains("password") && (body.contains("attached") || body.contains("enclosed") || body.contains("zip")) {
                signals.append(ThreatSignal(category: .content, severity: 0.7, detail: "Password-protected attachment pattern"))
                totalScore += 1.0
            }

            guard !signals.isEmpty else { return nil }

            let normalizedScore = min(1.0, totalScore / 10.0)
            let threatLevel: ThreatCorrelation.ThreatLevel
            switch normalizedScore {
            case 0.8...1.0: threatLevel = .critical
            case 0.6..<0.8: threatLevel = .high
            case 0.35..<0.6: threatLevel = .medium
            case 0.1..<0.35: threatLevel = .low
            default: threatLevel = .clean
            }

            let attackVector = classifyAttackVector(signals: signals, body: body)

            return ThreatCorrelation(
                id: email.id,
                email: email,
                compositeScore: normalizedScore,
                signals: signals,
                threatLevel: threatLevel,
                attackVector: attackVector
            )
        }.sorted { $0.compositeScore > $1.compositeScore }
    }

    private static func classifyAttackVector(signals: [ThreatSignal], body: String) -> ThreatCorrelation.AttackVector? {
        let hasAuthIssues = signals.contains { $0.category == .authentication }
        let hasContentFlags = signals.contains { $0.category == .content }
        let hasTechnical = signals.contains { $0.category == .technical }

        if body.contains("wire transfer") || body.contains("bank account") || body.contains("routing number") {
            return .businessEmailCompromise
        }
        if hasTechnical {
            return .malwareDelivery
        }
        if body.contains("password") || body.contains("credential") || body.contains("sign in") || body.contains("verify your account") {
            return .credentialHarvesting
        }
        if hasAuthIssues && hasContentFlags {
            return .spearPhishing
        }
        if hasAuthIssues && !hasContentFlags {
            return .spoofing
        }
        if hasContentFlags {
            return .phishing
        }
        return nil
    }

    // MARK: - Domain Reputation Scoring

    static func scoreDomainReputations(
        emails: [MBOXParser.RawEmail],
        phishingFlags: [EmailNLPEngine.PhishingFlag] = []
    ) -> [DomainReputation] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var domainData: [String: (emails: [MBOXParser.RawEmail], dates: [Date])] = [:]

        for email in emails {
            let from = email.headers["From"] ?? ""
            guard let domain = extractDomain(from: from), !domain.isEmpty else { continue }
            var entry = domainData[domain, default: ([], [])]
            entry.emails.append(email)
            if let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) {
                entry.dates.append(date)
            }
            domainData[domain] = entry
        }

        let phishingDomains = Dictionary(grouping: phishingFlags) { flag -> String in
            extractDomain(from: flag.email.headers["From"] ?? "") ?? ""
        }

        return domainData.map { domain, data -> DomainReputation in
            var score: Double = 0.5
            var riskFactors: [String] = []

            var authPass = 0
            var authTotal = 0
            for email in data.emails {
                let auth = EmailNLPEngine.parseAuthenticationResults(email.headers)
                if auth.spfResult != .none || auth.dkimResult != .none || auth.dmarcResult != .none {
                    authTotal += 1
                    if auth.isFullyAuthenticated {
                        authPass += 1
                    }
                }
            }
            let authRate = authTotal > 0 ? Double(authPass) / Double(authTotal) : 0.5
            score += (authRate - 0.5) * 0.3

            if authRate < 0.3 && authTotal > 2 {
                riskFactors.append("Low authentication pass rate (\(Int(authRate * 100))%)")
                score -= 0.15
            }

            let phishCount = phishingDomains[domain]?.count ?? 0
            let phishRate = data.emails.count > 0 ? Double(phishCount) / Double(data.emails.count) : 0
            if phishRate > 0.3 {
                riskFactors.append("High phishing flag rate (\(Int(phishRate * 100))%)")
                score -= 0.25
            } else if phishRate > 0.1 {
                riskFactors.append("Moderate phishing indicators")
                score -= 0.1
            }

            if data.emails.count >= 20 {
                score += 0.1
            }
            if data.emails.count < 3 {
                riskFactors.append("Low email volume — insufficient history")
                score -= 0.05
            }

            let sortedDates = data.dates.sorted()
            let firstSeen = sortedDates.first
            let lastSeen = sortedDates.last
            if let first = firstSeen {
                let age = Date().timeIntervalSince(first)
                if age < 7 * 86400 {
                    riskFactors.append("Domain first seen within last 7 days")
                    score -= 0.15
                } else if age > 180 * 86400 {
                    score += 0.1
                }
            }

            let suspiciousTLDs = ["xyz", "tk", "ml", "ga", "cf", "gq", "top", "buzz", "club", "icu", "work"]
            let tld = domain.components(separatedBy: ".").last ?? ""
            if suspiciousTLDs.contains(tld) {
                riskFactors.append("High-risk TLD (.\(tld))")
                score -= 0.2
            }

            let clampedScore = max(0, min(1.0, score))
            let category: DomainReputation.DomainCategory
            switch clampedScore {
            case 0.75...1.0: category = .trusted
            case 0.5..<0.75: category = .known
            case 0.3..<0.5: category = .suspicious
            case 0..<0.3: category = .malicious
            default:
                if data.emails.count < 3 { category = .newUnverified }
                else { category = .known }
            }

            return DomainReputation(
                id: domain,
                domain: domain,
                score: clampedScore,
                emailCount: data.emails.count,
                authenticationRate: authRate,
                phishingRate: phishRate,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                riskFactors: riskFactors,
                category: data.emails.count < 3 ? .newUnverified : category
            )
        }.sorted { $0.score < $1.score }
    }

    // MARK: - Compromised Account Detection

    static func detectCompromisedAccounts(
        emails: [MBOXParser.RawEmail],
        anomalies: [AnomalyDetectionEngine.Anomaly] = []
    ) -> [CompromiseIndicator] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var senderEmails: [String: [(email: MBOXParser.RawEmail, date: Date?)]] = [:]
        for email in emails {
            let from = extractEmailAddress(from: email.headers["From"] ?? "")
            guard !from.isEmpty else { continue }
            let date = email.headers["Date"].flatMap { formatter.date(from: $0) }
            senderEmails[from, default: []].append((email, date))
        }

        let unusualHourIDs = Set(anomalies.filter { $0.type == .unusualHour }.flatMap { $0.affectedEmails })
        let toneShiftIDs = Set(anomalies.filter { $0.type == .toneShift }.flatMap { $0.affectedEmails })

        var results: [CompromiseIndicator] = []

        for (account, entries) in senderEmails {
            guard entries.count >= 5 else { continue }

            var indicators: [String] = []
            var confidence: Double = 0

            let accountEmails = entries.map { $0.email }
            let unusualHourEmails = accountEmails.filter { unusualHourIDs.contains($0.id) }
            if unusualHourEmails.count >= 3 {
                indicators.append("Unusual sending hours detected (\(unusualHourEmails.count) emails between midnight-5am)")
                confidence += 0.25
            }

            if accountEmails.contains(where: { toneShiftIDs.contains($0.id) }) {
                indicators.append("Significant tone shift detected in recent communications")
                confidence += 0.2
            }

            let sortedByDate = entries.compactMap { entry -> (MBOXParser.RawEmail, Date)? in
                guard let date = entry.date else { return nil }
                return (entry.email, date)
            }.sorted { $0.1 < $1.1 }

            if sortedByDate.count >= 10 {
                let midpoint = sortedByDate.count / 2
                let earlyRecipients = Set(sortedByDate.prefix(midpoint).flatMap { extractRecipients(from: $0.0) })
                let lateRecipients = Set(sortedByDate.suffix(sortedByDate.count - midpoint).flatMap { extractRecipients(from: $0.0) })
                let newRecipients = lateRecipients.subtracting(earlyRecipients)
                let newRatio = earlyRecipients.isEmpty ? 0 : Double(newRecipients.count) / Double(earlyRecipients.count)
                if newRatio > 0.5 && newRecipients.count >= 5 {
                    indicators.append("Sudden shift to \(newRecipients.count) new recipients not seen historically")
                    confidence += 0.3
                }
            }

            let recentEmails = sortedByDate.suffix(20)
            var sentToLargeGroups = 0
            for (email, _) in recentEmails {
                let recipientCount = extractRecipients(from: email).count
                if recipientCount > 10 {
                    sentToLargeGroups += 1
                }
            }
            if sentToLargeGroups >= 3 {
                indicators.append("Multiple recent emails sent to large recipient groups (\(sentToLargeGroups) emails with 10+ recipients)")
                confidence += 0.2
            }

            guard confidence >= 0.3 else { continue }

            let dates = sortedByDate.map { $0.1 }
            let timeWindow: (Date, Date)? = dates.count >= 2 ? (dates.first!, dates.last!) : nil

            results.append(CompromiseIndicator(
                id: UUID(),
                accountEmail: account,
                confidence: min(1.0, confidence),
                indicators: indicators,
                affectedEmails: accountEmails,
                timeWindow: timeWindow
            ))
        }

        return results.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Security Incident Timeline

    static func buildSecurityTimeline(
        emails: [MBOXParser.RawEmail],
        threats: [ThreatCorrelation] = [],
        phishingFlags: [EmailNLPEngine.PhishingFlag] = [],
        anomalies: [AnomalyDetectionEngine.Anomaly] = []
    ) -> [SecurityEvent] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var events: [SecurityEvent] = []

        let threatsByDate: [Date: [ThreatCorrelation]] = Dictionary(grouping: threats.filter { $0.threatLevel >= .medium }) { threat in
            let dateStr = threat.email.headers["Date"] ?? ""
            return formatter.date(from: dateStr) ?? Date.distantPast
        }

        for (date, dayThreats) in threatsByDate where date != Date.distantPast {
            if dayThreats.count >= 3 {
                events.append(SecurityEvent(
                    id: UUID(),
                    timestamp: date,
                    eventType: .bulkSuspicious,
                    severity: dayThreats.map(\.compositeScore).max() ?? 0.5,
                    summary: "\(dayThreats.count) threat-correlated emails detected",
                    affectedEmails: dayThreats.map(\.id)
                ))
            }

            let phishingThreats = dayThreats.filter { $0.attackVector == .phishing || $0.attackVector == .spearPhishing || $0.attackVector == .credentialHarvesting }
            if phishingThreats.count >= 2 {
                events.append(SecurityEvent(
                    id: UUID(),
                    timestamp: date,
                    eventType: .phishingCampaign,
                    severity: 0.85,
                    summary: "Potential phishing campaign: \(phishingThreats.count) related phishing emails",
                    affectedEmails: phishingThreats.map(\.id)
                ))
            }
        }

        let spoofingThreats = threats.filter { $0.attackVector == .spoofing }
        for threat in spoofingThreats {
            let date = formatter.date(from: threat.email.headers["Date"] ?? "") ?? Date()
            events.append(SecurityEvent(
                id: UUID(),
                timestamp: date,
                eventType: .spoofingAttempt,
                severity: threat.compositeScore,
                summary: "Spoofing attempt from \(threat.email.headers["From"] ?? "unknown")",
                affectedEmails: [threat.id]
            ))
        }

        for anomaly in anomalies where anomaly.severity >= 0.5 {
            let eventType: SecurityEvent.SecurityEventType
            switch anomaly.type {
            case .unusualHour: eventType = .accountAnomaly
            case .newDomain: eventType = .newThreatDomain
            case .recipientAnomaly: eventType = .dataExfiltration
            default: continue
            }
            events.append(SecurityEvent(
                id: UUID(),
                timestamp: anomaly.timestamp ?? Date(),
                eventType: eventType,
                severity: anomaly.severity,
                summary: anomaly.title,
                affectedEmails: anomaly.affectedEmails
            ))
        }

        return events.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Authentication Health

    static func analyzeAuthenticationHealth(emails: [MBOXParser.RawEmail]) -> [AuthenticationHealth] {
        var domainEmails: [String: [MBOXParser.RawEmail]] = [:]
        for email in emails {
            guard let domain = extractDomain(from: email.headers["From"] ?? ""), !domain.isEmpty else { continue }
            domainEmails[domain, default: []].append(email)
        }

        return domainEmails.map { domain, emails -> AuthenticationHealth in
            var spfPass = 0, spfFail = 0
            var dkimPass = 0, dkimFail = 0
            var dmarcPass = 0, dmarcFail = 0

            for email in emails {
                let auth = EmailNLPEngine.parseAuthenticationResults(email.headers)
                switch auth.spfResult {
                case .pass, .bestguesspass: spfPass += 1
                case .fail, .softfail: spfFail += 1
                default: break
                }
                switch auth.dkimResult {
                case .pass: dkimPass += 1
                case .fail: dkimFail += 1
                default: break
                }
                switch auth.dmarcResult {
                case .pass: dmarcPass += 1
                case .fail: dmarcFail += 1
                default: break
                }
            }

            let totalChecks = max(1, spfPass + spfFail + dkimPass + dkimFail + dmarcPass + dmarcFail)
            let totalPasses = spfPass + dkimPass + dmarcPass
            let overallScore = Double(totalPasses) / Double(totalChecks)

            return AuthenticationHealth(
                domain: domain,
                totalEmails: emails.count,
                spfPass: spfPass,
                spfFail: spfFail,
                dkimPass: dkimPass,
                dkimFail: dkimFail,
                dmarcPass: dmarcPass,
                dmarcFail: dmarcFail,
                overallScore: overallScore
            )
        }.sorted { $0.overallScore < $1.overallScore }
    }

    // MARK: - Helpers

    private static func extractDomain(from text: String) -> String? {
        let address = extractEmailAddress(from: text)
        guard let atIndex = address.range(of: "@") else { return nil }
        return String(address[atIndex.upperBound...]).lowercased()
    }

    private static func extractEmailAddress(from text: String) -> String {
        if let start = text.range(of: "<"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.contains("@") ? trimmed : ""
    }

    private static func extractRecipients(from email: MBOXParser.RawEmail) -> [String] {
        let to = email.headers["To"] ?? ""
        let cc = email.headers["Cc"] ?? ""
        return (to + "," + cc).components(separatedBy: ",").compactMap { part -> String? in
            let addr = extractEmailAddress(from: part)
            return addr.isEmpty ? nil : addr
        }
    }
}
