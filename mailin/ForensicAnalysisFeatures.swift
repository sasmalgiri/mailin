import Foundation
import NaturalLanguage

struct ForensicAnalysisFeatures {

    // MARK: - Types

    struct EvidenceRelevanceScore: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let score: Double
        let reasons: [String]
        let relevanceLevel: RelevanceLevel
        let keyEntities: [String]
        let matchedKeywords: [String]

        enum RelevanceLevel: String, CaseIterable, Comparable {
            case critical = "Critical"
            case high = "High"
            case medium = "Medium"
            case low = "Low"
            case irrelevant = "Irrelevant"

            static func < (lhs: RelevanceLevel, rhs: RelevanceLevel) -> Bool {
                let order: [RelevanceLevel] = [.irrelevant, .low, .medium, .high, .critical]
                return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
            }
        }
    }

    struct ForensicTimelineEvent: Identifiable {
        let id: UUID
        let timestamp: Date
        let eventType: ForensicEventType
        let summary: String
        let evidenceStrength: Double
        let relatedEmails: [UUID]
        let participants: [String]

        enum ForensicEventType: String, CaseIterable {
            case communication = "Communication"
            case evidenceCreation = "Evidence Creation"
            case deletionGap = "Deletion Gap"
            case patternChange = "Pattern Change"
            case spoofingAttempt = "Spoofing Attempt"
            case piiExposure = "PII Exposure"
            case attachmentTransfer = "Attachment Transfer"
        }
    }

    struct SuspiciousPattern: Identifiable {
        let id: UUID
        let patternType: PatternType
        let severity: Double
        let description: String
        let affectedEmails: [MBOXParser.RawEmail]
        let indicators: [String]

        enum PatternType: String, CaseIterable {
            case timeGap = "Communication Gap"
            case headerManipulation = "Header Manipulation"
            case timestampAnomaly = "Timestamp Anomaly"
            case routingAnomaly = "Routing Anomaly"
            case contentDestruction = "Content Destruction"
            case coordinatedActivity = "Coordinated Activity"
        }
    }

    struct EvidenceCluster: Identifiable {
        let id: UUID
        let topic: String
        let emails: [MBOXParser.RawEmail]
        let participants: Set<String>
        let dateRange: (start: Date, end: Date)?
        let cohesionScore: Double
        let keyTerms: [String]
    }

    struct MetadataAnomaly: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let anomalyType: MetadataAnomalyType
        let severity: Double
        let detail: String
        let forensicSignificance: String

        enum MetadataAnomalyType: String, CaseIterable {
            case timezoneInconsistency = "Timezone Inconsistency"
            case missingMessageID = "Missing Message-ID"
            case forgedHeaders = "Forged Headers"
            case mismatchedDates = "Mismatched Dates"
            case suspiciousXHeaders = "Suspicious X-Headers"
            case strippedHeaders = "Stripped Headers"
            case encodingAnomaly = "Encoding Anomaly"
        }
    }

    // MARK: - Evidence Relevance Scoring

    static func scoreEvidenceRelevance(
        emails: [MBOXParser.RawEmail],
        caseKeywords: [String] = [],
        custodians: [String] = []
    ) -> [EvidenceRelevanceScore] {
        let loweredKeywords = caseKeywords.map { $0.lowercased() }
        let loweredCustodians = custodians.map { $0.lowercased() }
        let tagger = NLTagger(tagSchemes: [.nameType, .sentimentScore])

        return emails.map { email -> EvidenceRelevanceScore in
            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody)
            let bodyLower = body.lowercased()
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()
            let to = ((email.headers["To"] ?? "") + "," + (email.headers["Cc"] ?? "")).lowercased()

            var score: Double = 0
            var reasons: [String] = []
            var matched: [String] = []

            for keyword in loweredKeywords {
                let bodyCount = countOccurrences(of: keyword, in: bodyLower)
                let subjectCount = countOccurrences(of: keyword, in: subject)
                if bodyCount > 0 || subjectCount > 0 {
                    score += Double(min(bodyCount, 5)) * 0.1 + Double(subjectCount) * 0.2
                    matched.append(keyword)
                    reasons.append("Keyword '\(keyword)' found \(bodyCount + subjectCount) times")
                }
            }

            for custodian in loweredCustodians {
                if from.contains(custodian) {
                    score += 0.3
                    reasons.append("From custodian: \(custodian)")
                }
                if to.contains(custodian) {
                    score += 0.2
                    reasons.append("To custodian: \(custodian)")
                }
            }

            if !email.attachments.isEmpty {
                score += 0.1 * Double(min(email.attachments.count, 5))
                reasons.append("\(email.attachments.count) attachment(s)")
            }

            if email.headers["In-Reply-To"] != nil || email.inReplyTo != nil {
                score += 0.05
            }

            var entities: [String] = []
            let textForNER = String(body.prefix(2000))
            tagger.string = textForNER
            tagger.enumerateTags(in: textForNER.startIndex..<textForNER.endIndex, unit: .word, scheme: .nameType) { tag, range in
                if tag == .personalName || tag == .organizationName {
                    let entity = String(textForNER[range])
                    if entity.count > 2 { entities.append(entity) }
                }
                return true
            }

            if entities.count >= 5 {
                score += 0.1
                reasons.append("Rich in named entities (\(entities.count))")
            }

            tagger.string = String(body.prefix(500))
            if let sentimentTag = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore).0,
               let sentiment = Double(sentimentTag.rawValue) {
                if abs(sentiment) > 0.5 {
                    score += 0.05
                    reasons.append("Strong sentiment detected (\(sentiment > 0 ? "positive" : "negative"))")
                }
            }

            let legalTerms = ["confidential", "privileged", "settlement", "litigation", "subpoena",
                              "deposition", "discovery", "complaint", "defendant", "plaintiff",
                              "contract", "agreement", "indemnif", "breach", "damages"]
            for term in legalTerms where bodyLower.contains(term) {
                score += 0.05
                reasons.append("Legal term: '\(term)'")
            }

            let normalizedScore = min(1.0, score)
            let level: EvidenceRelevanceScore.RelevanceLevel
            switch normalizedScore {
            case 0.7...1.0: level = .critical
            case 0.5..<0.7: level = .high
            case 0.3..<0.5: level = .medium
            case 0.1..<0.3: level = .low
            default: level = .irrelevant
            }

            return EvidenceRelevanceScore(
                id: email.id,
                email: email,
                score: normalizedScore,
                reasons: reasons,
                relevanceLevel: level,
                keyEntities: Array(Set(entities)).sorted(),
                matchedKeywords: matched
            )
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Forensic Timeline Reconstruction

    static func reconstructTimeline(
        emails: [MBOXParser.RawEmail],
        piiFindings: [EmailNLPEngine.PIIFinding] = [],
        spoofIndicators: [(email: MBOXParser.RawEmail, severity: String)] = []
    ) -> [ForensicTimelineEvent] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var events: [ForensicTimelineEvent] = []

        let dated: [(MBOXParser.RawEmail, Date)] = emails.compactMap { email in
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { return nil }
            return (email, date)
        }.sorted { $0.1 < $1.1 }

        for (email, date) in dated {
            let participants = extractParticipants(from: email)
            let subject = email.headers["Subject"] ?? "(No Subject)"

            events.append(ForensicTimelineEvent(
                id: UUID(),
                timestamp: date,
                eventType: .communication,
                summary: subject,
                evidenceStrength: 0.5,
                relatedEmails: [email.id],
                participants: participants
            ))

            if !email.attachments.isEmpty {
                let filenames = email.attachments.map(\.filename).joined(separator: ", ")
                events.append(ForensicTimelineEvent(
                    id: UUID(),
                    timestamp: date,
                    eventType: .attachmentTransfer,
                    summary: "Attachment transfer: \(filenames)",
                    evidenceStrength: 0.6,
                    relatedEmails: [email.id],
                    participants: participants
                ))
            }
        }

        if dated.count >= 5 {
            for i in 1..<dated.count {
                let gap = dated[i].1.timeIntervalSince(dated[i-1].1)
                let avgGap = dated.last!.1.timeIntervalSince(dated.first!.1) / Double(dated.count)
                if gap > avgGap * 5 && gap > 7 * 86400 {
                    let dayGap = Int(gap / 86400)
                    events.append(ForensicTimelineEvent(
                        id: UUID(),
                        timestamp: dated[i-1].1,
                        eventType: .deletionGap,
                        summary: "\(dayGap)-day gap in communications (potential deletion or collection gap)",
                        evidenceStrength: min(1.0, gap / (30 * 86400)),
                        relatedEmails: [dated[i-1].0.id, dated[i].0.id],
                        participants: []
                    ))
                }
            }
        }

        let piiByEmail = Dictionary(grouping: piiFindings, by: { $0.emailID })
        for (emailID, findings) in piiByEmail {
            if let (email, date) = dated.first(where: { $0.0.id == emailID }) {
                let types = Set(findings.map(\.type.rawValue)).joined(separator: ", ")
                events.append(ForensicTimelineEvent(
                    id: UUID(),
                    timestamp: date,
                    eventType: .piiExposure,
                    summary: "PII exposed: \(types) (\(findings.count) instances)",
                    evidenceStrength: findings.map(\.contextualRiskScore).max() ?? 0.5,
                    relatedEmails: [emailID],
                    participants: extractParticipants(from: email)
                ))
            }
        }

        for indicator in spoofIndicators {
            if let date = indicator.email.headers["Date"].flatMap({ formatter.date(from: $0) }) {
                events.append(ForensicTimelineEvent(
                    id: UUID(),
                    timestamp: date,
                    eventType: .spoofingAttempt,
                    summary: "Spoofing detected (\(indicator.severity)) from \(indicator.email.headers["From"] ?? "unknown")",
                    evidenceStrength: indicator.severity == "high" ? 0.9 : (indicator.severity == "medium" ? 0.6 : 0.3),
                    relatedEmails: [indicator.email.id],
                    participants: extractParticipants(from: indicator.email)
                ))
            }
        }

        return events.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Suspicious Pattern Detection

    static func detectSuspiciousPatterns(in emails: [MBOXParser.RawEmail]) -> [SuspiciousPattern] {
        var patterns: [SuspiciousPattern] = []

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let dated = emails.compactMap { email -> (MBOXParser.RawEmail, Date)? in
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { return nil }
            return (email, date)
        }.sorted { $0.1 < $1.1 }

        patterns.append(contentsOf: detectTimestampAnomalies(emails: emails, formatter: formatter))
        patterns.append(contentsOf: detectHeaderManipulation(emails: emails))
        patterns.append(contentsOf: detectCommunicationGaps(dated: dated))
        patterns.append(contentsOf: detectCoordinatedActivity(dated: dated))

        return patterns.sorted { $0.severity > $1.severity }
    }

    private static func detectTimestampAnomalies(emails: [MBOXParser.RawEmail], formatter: DateFormatter) -> [SuspiciousPattern] {
        var results: [SuspiciousPattern] = []

        for email in emails {
            guard let dateHeader = email.headers["Date"],
                  let headerDate = formatter.date(from: dateHeader) else { continue }

            let received = email.headers["Received"] ?? ""
            let receivedDates = extractDatesFromReceived(received, formatter: formatter)

            for receivedDate in receivedDates {
                let diff = abs(headerDate.timeIntervalSince(receivedDate))
                if diff > 3600 * 24 {
                    let hours = Int(diff / 3600)
                    results.append(SuspiciousPattern(
                        id: UUID(),
                        patternType: .timestampAnomaly,
                        severity: min(1.0, diff / (3600 * 72)),
                        description: "Date header differs from Received header by \(hours) hours — possible backdating or clock manipulation",
                        affectedEmails: [email],
                        indicators: ["Date: \(dateHeader)", "Received timestamp differs by \(hours)h"]
                    ))
                    break
                }
            }

            if let dateStr = email.headers["Date"] {
                let timezonePattern = try? NSRegularExpression(pattern: #"[+-]\d{4}$"#)
                let matches = timezonePattern?.matches(in: dateStr, range: NSRange(dateStr.startIndex..., in: dateStr)) ?? []
                if matches.isEmpty && !dateStr.contains("GMT") && !dateStr.contains("UTC") {
                    results.append(SuspiciousPattern(
                        id: UUID(),
                        patternType: .timestampAnomaly,
                        severity: 0.3,
                        description: "Missing timezone in Date header — may indicate header manipulation",
                        affectedEmails: [email],
                        indicators: ["Date header: \(dateStr)", "No timezone offset found"]
                    ))
                }
            }
        }

        return results
    }

    private static func detectHeaderManipulation(emails: [MBOXParser.RawEmail]) -> [SuspiciousPattern] {
        var results: [SuspiciousPattern] = []

        for email in emails {
            var indicators: [String] = []
            var severity: Double = 0

            if email.headers["Message-ID"] == nil || (email.headers["Message-ID"] ?? "").isEmpty {
                indicators.append("Missing Message-ID header")
                severity += 0.3
            }

            if let messageID = email.headers["Message-ID"], !messageID.contains("@") {
                indicators.append("Malformed Message-ID (no @ symbol)")
                severity += 0.4
            }

            let from = email.headers["From"] ?? ""
            let returnPath = email.headers["Return-Path"] ?? ""
            if !returnPath.isEmpty && !from.isEmpty {
                let fromDomain = extractDomain(from: from)
                let returnDomain = extractDomain(from: returnPath)
                if !fromDomain.isEmpty && !returnDomain.isEmpty && fromDomain != returnDomain {
                    indicators.append("From domain (\(fromDomain)) differs from Return-Path domain (\(returnDomain))")
                    severity += 0.5
                }
            }

            let receivedCount = email.rawSource.components(separatedBy: "Received:").count - 1
            if receivedCount == 0 {
                indicators.append("No Received headers — email may be fabricated")
                severity += 0.7
            } else if receivedCount > 15 {
                indicators.append("Excessive Received headers (\(receivedCount)) — possible relay manipulation")
                severity += 0.3
            }

            let xMailer = email.headers["X-Mailer"] ?? email.headers["User-Agent"] ?? ""
            let suspiciousMailers = ["mass mailer", "bulk sender", "anonymous", "hidden"]
            for mailer in suspiciousMailers where xMailer.lowercased().contains(mailer) {
                indicators.append("Suspicious mailer: \(xMailer)")
                severity += 0.4
                break
            }

            if !indicators.isEmpty {
                results.append(SuspiciousPattern(
                    id: UUID(),
                    patternType: .headerManipulation,
                    severity: min(1.0, severity),
                    description: "Header integrity concerns detected in email from \(email.headers["From"] ?? "unknown")",
                    affectedEmails: [email],
                    indicators: indicators
                ))
            }
        }

        return results
    }

    private static func detectCommunicationGaps(dated: [(MBOXParser.RawEmail, Date)]) -> [SuspiciousPattern] {
        guard dated.count >= 10 else { return [] }

        var gaps: [(gap: TimeInterval, before: MBOXParser.RawEmail, after: MBOXParser.RawEmail)] = []
        for i in 1..<dated.count {
            let gap = dated[i].1.timeIntervalSince(dated[i-1].1)
            gaps.append((gap, dated[i-1].0, dated[i].0))
        }

        let avgGap = gaps.map(\.gap).reduce(0, +) / Double(gaps.count)
        let stdDev = sqrt(gaps.map { ($0.gap - avgGap) * ($0.gap - avgGap) }.reduce(0, +) / Double(gaps.count))

        return gaps.compactMap { gap, before, after -> SuspiciousPattern? in
            guard gap > avgGap + 3 * stdDev && gap > 3 * 86400 else { return nil }

            let days = Int(gap / 86400)
            return SuspiciousPattern(
                id: UUID(),
                patternType: .timeGap,
                severity: min(1.0, (gap - avgGap) / (stdDev * 6)),
                description: "\(days)-day communication gap — \(days > 30 ? "significant collection gap or deliberate deletion" : "unusual silence period")",
                affectedEmails: [before, after],
                indicators: [
                    "Gap: \(days) days",
                    "Average interval: \(Int(avgGap / 86400)) days",
                    "Standard deviation: \(Int(stdDev / 86400)) days"
                ]
            )
        }
    }

    private static func detectCoordinatedActivity(dated: [(MBOXParser.RawEmail, Date)]) -> [SuspiciousPattern] {
        guard dated.count >= 20 else { return [] }

        let calendar = Calendar.current
        var hourBuckets: [Int: [(MBOXParser.RawEmail, Date)]] = [:]

        for entry in dated {
            let hour = calendar.component(.hour, from: entry.1)
            hourBuckets[hour, default: []].append(entry)
        }

        var results: [SuspiciousPattern] = []

        for (hour, entries) in hourBuckets {
            guard entries.count >= 5 else { continue }

            var senderCounts: [String: Int] = [:]
            for (email, _) in entries {
                let from = (email.headers["From"] ?? "").lowercased()
                senderCounts[from, default: 0] += 1
            }

            let multiSenderSameHour = senderCounts.filter { $0.value >= 3 }
            if multiSenderSameHour.count >= 2 {
                let senders = multiSenderSameHour.keys.prefix(3).joined(separator: ", ")
                results.append(SuspiciousPattern(
                    id: UUID(),
                    patternType: .coordinatedActivity,
                    severity: min(1.0, Double(multiSenderSameHour.count) / 5.0),
                    description: "Multiple senders consistently active at \(hour):00 — possible coordinated or automated activity",
                    affectedEmails: Array(entries.prefix(5).map(\.0)),
                    indicators: [
                        "\(multiSenderSameHour.count) senders with 3+ emails at \(hour):00",
                        "Senders: \(senders)"
                    ]
                ))
            }
        }

        return results
    }

    // MARK: - Evidence Clustering

    static func clusterEvidence(emails: [MBOXParser.RawEmail]) -> [EvidenceCluster] {
        guard emails.count >= 5, let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let capped = emails.count > 500 ? Array(emails.prefix(500)) : emails

        struct EmailVector {
            let email: MBOXParser.RawEmail
            let text: String
            let date: Date?
        }

        let vectors: [EmailVector] = capped.map { email in
            let subject = email.headers["Subject"] ?? ""
            let body = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(300))
            let text = subject + " " + body
            let date = email.headers["Date"].flatMap { formatter.date(from: $0) }
            return EmailVector(email: email, text: text, date: date)
        }

        var clusters: [[Int]] = []
        var assigned = Set<Int>()

        for i in 0..<vectors.count {
            guard !assigned.contains(i) else { continue }

            var cluster = [i]
            assigned.insert(i)

            for j in (i+1)..<vectors.count {
                guard !assigned.contains(j) else { continue }

                let distance = embedding.distance(between: vectors[i].text, and: vectors[j].text, distanceType: .cosine)
                if distance < 0.4 {
                    cluster.append(j)
                    assigned.insert(j)
                }
            }

            if cluster.count >= 2 {
                clusters.append(cluster)
            }
        }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])

        return clusters.map { indices -> EvidenceCluster in
            let clusterEmails = indices.map { vectors[$0].email }
            let participants = Set(clusterEmails.flatMap { extractParticipants(from: $0) })
            let dates = indices.compactMap { vectors[$0].date }.sorted()

            var termCounts: [String: Int] = [:]
            for idx in indices.prefix(10) {
                let text = String(vectors[idx].text.prefix(500))
                tagger.string = text
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
                    if tag == .noun {
                        let word = String(text[range]).lowercased()
                        if word.count > 3 { termCounts[word, default: 0] += 1 }
                    }
                    return true
                }
            }
            let keyTerms = termCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            let topic = keyTerms.first ?? "Unknown"

            let avgDistance: Double
            if indices.count >= 2 {
                var totalDist: Double = 0
                var pairs = 0
                for a in 0..<min(indices.count, 10) {
                    for b in (a+1)..<min(indices.count, 10) {
                        totalDist += embedding.distance(between: vectors[indices[a]].text, and: vectors[indices[b]].text, distanceType: .cosine)
                        pairs += 1
                    }
                }
                avgDistance = pairs > 0 ? totalDist / Double(pairs) : 0.5
            } else {
                avgDistance = 0
            }

            return EvidenceCluster(
                id: UUID(),
                topic: topic.capitalized,
                emails: clusterEmails,
                participants: participants,
                dateRange: dates.count >= 2 ? (dates.first!, dates.last!) : nil,
                cohesionScore: max(0, 1.0 - avgDistance),
                keyTerms: keyTerms
            )
        }.sorted { $0.emails.count > $1.emails.count }
    }

    // MARK: - Metadata Anomaly Detection

    static func detectMetadataAnomalies(in emails: [MBOXParser.RawEmail]) -> [MetadataAnomaly] {
        var anomalies: [MetadataAnomaly] = []

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        for email in emails {
            if email.headers["Message-ID"] == nil {
                anomalies.append(MetadataAnomaly(
                    id: UUID(),
                    email: email,
                    anomalyType: .missingMessageID,
                    severity: 0.6,
                    detail: "Email lacks Message-ID header",
                    forensicSignificance: "Missing Message-ID may indicate header stripping, fabrication, or non-standard mail client"
                ))
            }

            let from = email.headers["From"] ?? ""
            let returnPath = email.headers["Return-Path"] ?? ""
            if !returnPath.isEmpty && !from.isEmpty {
                let fromDomain = extractDomain(from: from)
                let returnDomain = extractDomain(from: returnPath)
                if !fromDomain.isEmpty && !returnDomain.isEmpty && fromDomain != returnDomain {
                    anomalies.append(MetadataAnomaly(
                        id: UUID(),
                        email: email,
                        anomalyType: .forgedHeaders,
                        severity: 0.7,
                        detail: "From domain (\(fromDomain)) ≠ Return-Path domain (\(returnDomain))",
                        forensicSignificance: "Domain mismatch suggests potential header forgery or mailing list relay"
                    ))
                }
            }

            if let dateStr = email.headers["Date"], let headerDate = formatter.date(from: dateStr) {
                let received = email.headers["Received"] ?? ""
                let receivedDates = extractDatesFromReceived(received, formatter: formatter)
                for recvDate in receivedDates {
                    let diff = headerDate.timeIntervalSince(recvDate)
                    if diff > 86400 {
                        anomalies.append(MetadataAnomaly(
                            id: UUID(),
                            email: email,
                            anomalyType: .mismatchedDates,
                            severity: min(1.0, abs(diff) / (86400 * 7)),
                            detail: "Date header is \(Int(diff / 3600)) hours ahead of Received timestamp",
                            forensicSignificance: "Future-dated email relative to receipt — possible backdating or clock tampering"
                        ))
                        break
                    } else if diff < -86400 * 7 {
                        anomalies.append(MetadataAnomaly(
                            id: UUID(),
                            email: email,
                            anomalyType: .mismatchedDates,
                            severity: min(1.0, abs(diff) / (86400 * 30)),
                            detail: "Date header is \(Int(abs(diff) / 86400)) days behind Received timestamp",
                            forensicSignificance: "Significantly backdated email — possible evidence tampering"
                        ))
                        break
                    }
                }
            }

            let expectedHeaders = ["From", "Date", "Subject"]
            let missing = expectedHeaders.filter { email.headers[$0] == nil || (email.headers[$0] ?? "").isEmpty }
            if missing.count >= 2 {
                anomalies.append(MetadataAnomaly(
                    id: UUID(),
                    email: email,
                    anomalyType: .strippedHeaders,
                    severity: 0.5 + Double(missing.count) * 0.1,
                    detail: "Missing essential headers: \(missing.joined(separator: ", "))",
                    forensicSignificance: "Multiple missing standard headers suggest content stripping or reconstruction"
                ))
            }

            let contentType = email.headers["Content-Type"] ?? ""
            if contentType.contains("charset") {
                let charset = contentType.lowercased()
                if charset.contains("utf-7") || charset.contains("hz-gb") || charset.contains("viscii") {
                    anomalies.append(MetadataAnomaly(
                        id: UUID(),
                        email: email,
                        anomalyType: .encodingAnomaly,
                        severity: 0.5,
                        detail: "Unusual character encoding detected in Content-Type",
                        forensicSignificance: "Rare encoding may be used to evade content filtering or hide text"
                    ))
                }
            }
        }

        return anomalies.sorted { $0.severity > $1.severity }
    }

    // MARK: - Helpers

    private static func extractParticipants(from email: MBOXParser.RawEmail) -> [String] {
        var participants: [String] = []
        if let from = email.headers["From"] { participants.append(from) }
        let to = (email.headers["To"] ?? "").components(separatedBy: ",")
        let cc = (email.headers["Cc"] ?? "").components(separatedBy: ",")
        participants.append(contentsOf: (to + cc).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return participants
    }

    private static func extractDomain(from text: String) -> String {
        let lower = text.lowercased()
        if let atRange = lower.range(of: "@") {
            let afterAt = lower[atRange.upperBound...]
            let domain = afterAt.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted).first ?? ""
            return domain
        }
        return ""
    }

    private static func extractDatesFromReceived(_ received: String, formatter: DateFormatter) -> [Date] {
        let parts = received.components(separatedBy: ";")
        return parts.compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return formatter.date(from: trimmed)
        }
    }

    private static func countOccurrences(of term: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: term, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}
