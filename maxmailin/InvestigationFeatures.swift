import Foundation
import NaturalLanguage

struct InvestigationFeatures {

    // MARK: - Types

    struct SourceCredibility: Identifiable {
        let id: String
        let name: String
        let email: String
        let overallScore: Double
        let factors: [CredibilityFactor]
        let emailCount: Int
        let topicDiversity: Int
        let avgResponseTime: TimeInterval?

        struct CredibilityFactor {
            let name: String
            let score: Double
            let detail: String
        }
    }

    struct StoryLead: Identifiable {
        let id: UUID
        let headline: String
        let relevanceScore: Double
        let leadType: LeadType
        let supportingEmails: [MBOXParser.RawEmail]
        let keyEntities: [String]
        let suggestedAngle: String

        enum LeadType: String, CaseIterable {
            case patternBreak = "Pattern Break"
            case emergingTopic = "Emerging Topic"
            case conflictDetected = "Conflict Detected"
            case insiderSignal = "Insider Signal"
            case sentimentShift = "Sentiment Shift"
            case unusualConnection = "Unusual Connection"
        }
    }

    struct Contradiction: Identifiable {
        let id: UUID
        let claimA: ClaimInstance
        let claimB: ClaimInstance
        let similarity: Double
        let topic: String

        struct ClaimInstance {
            let email: MBOXParser.RawEmail
            let sender: String
            let snippet: String
            let date: Date?
        }
    }

    struct ExtractedQuote: Identifiable {
        let id: UUID
        let text: String
        let speaker: String
        let email: MBOXParser.RawEmail
        let context: String
        let newsworthiness: Double
    }

    struct TimelineEvent: Identifiable {
        let id: UUID
        let date: Date
        let summary: String
        let eventType: EventType
        let emails: [MBOXParser.RawEmail]
        let entities: [String]

        enum EventType: String, CaseIterable {
            case announcement = "Announcement"
            case decision = "Decision"
            case meeting = "Meeting"
            case deadline = "Deadline"
            case incident = "Incident"
            case communication = "Communication"
        }
    }

    // MARK: - Source Credibility Scoring

    static func scoreSourceCredibility(
        emails: [MBOXParser.RawEmail],
        graph: KnowledgeGraph? = nil
    ) -> [SourceCredibility] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var senderData: [String: (name: String, emails: [MBOXParser.RawEmail], dates: [Date])] = [:]
        for email in emails {
            let from = email.headers["From"] ?? ""
            let address = extractEmailAddress(from: from)
            guard !address.isEmpty else { continue }
            let name = extractDisplayName(from: from, fallback: address)
            var entry = senderData[address, default: (name, [], [])]
            entry.emails.append(email)
            if let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) {
                entry.dates.append(date)
            }
            senderData[address] = entry
        }

        let threadMap = buildThreadMap(emails: emails)

        return senderData.compactMap { address, data -> SourceCredibility? in
            guard data.emails.count >= 2 else { return nil }

            var factors: [SourceCredibility.CredibilityFactor] = []
            var totalScore: Double = 0
            var totalWeight: Double = 0

            let consistencyScore = measureConsistency(emails: data.emails)
            factors.append(.init(name: "Consistency", score: consistencyScore, detail: "Sentiment and topic consistency across communications"))
            totalScore += consistencyScore * 3.0
            totalWeight += 3.0

            let volumeScore = min(1.0, Double(data.emails.count) / 30.0)
            factors.append(.init(name: "Volume", score: volumeScore, detail: "\(data.emails.count) emails in archive"))
            totalScore += volumeScore * 1.5
            totalWeight += 1.5

            let sortedDates = data.dates.sorted()
            let spanScore: Double
            if sortedDates.count >= 2, let first = sortedDates.first, let last = sortedDates.last {
                let span = last.timeIntervalSince(first)
                spanScore = min(1.0, span / (180 * 86400))
            } else {
                spanScore = 0.1
            }
            factors.append(.init(name: "Longevity", score: spanScore, detail: "Communication span in archive"))
            totalScore += spanScore * 2.0
            totalWeight += 2.0

            let reciprocity = measureReciprocity(address: address, emails: emails, threadMap: threadMap)
            factors.append(.init(name: "Reciprocity", score: reciprocity, detail: "Two-way communication patterns"))
            totalScore += reciprocity * 2.5
            totalWeight += 2.5

            let topicDiversity = measureTopicDiversity(emails: data.emails)
            let diversityScore = min(1.0, Double(topicDiversity) / 8.0)
            factors.append(.init(name: "Topic Range", score: diversityScore, detail: "\(topicDiversity) distinct topics discussed"))
            totalScore += diversityScore * 1.0
            totalWeight += 1.0

            if let graph = graph {
                let nodeID = "person-\(address)"
                let neighbors = graph.neighbors(of: nodeID)
                let connectionScore = min(1.0, Double(neighbors.count) / 15.0)
                factors.append(.init(name: "Network Position", score: connectionScore, detail: "\(neighbors.count) connections in knowledge graph"))
                totalScore += connectionScore * 2.0
                totalWeight += 2.0
            }

            let avgResponseTime = calculateAvgResponseTime(address: address, dates: sortedDates, threadMap: threadMap, emails: emails)

            let overall = totalWeight > 0 ? totalScore / totalWeight : 0

            return SourceCredibility(
                id: address,
                name: data.name,
                email: address,
                overallScore: overall,
                factors: factors.sorted { $0.score > $1.score },
                emailCount: data.emails.count,
                topicDiversity: topicDiversity,
                avgResponseTime: avgResponseTime
            )
        }.sorted { $0.overallScore > $1.overallScore }
    }

    // MARK: - Story Lead Detection

    static func detectStoryLeads(
        emails: [MBOXParser.RawEmail],
        anomalies: [AnomalyDetectionEngine.Anomaly] = [],
        graph: KnowledgeGraph? = nil
    ) -> [StoryLead] {
        var leads: [StoryLead] = []

        let topicTrends = detectTopicTrends(emails: emails)
        for trend in topicTrends where trend.isEmerging {
            leads.append(StoryLead(
                id: UUID(),
                headline: "Emerging topic: '\(trend.topic)' — \(trend.recentCount) recent mentions vs \(trend.historicalCount) historical",
                relevanceScore: trend.growthRate,
                leadType: .emergingTopic,
                supportingEmails: trend.recentEmails,
                keyEntities: trend.relatedEntities,
                suggestedAngle: "Investigate why '\(trend.topic)' has surged in recent communications"
            ))
        }

        let toneShifts = anomalies.filter { $0.type == .toneShift }
        for shift in toneShifts {
            let affected = emails.filter { shift.affectedEmails.contains($0.id) }
            if !affected.isEmpty {
                leads.append(StoryLead(
                    id: UUID(),
                    headline: shift.title,
                    relevanceScore: shift.severity,
                    leadType: .sentimentShift,
                    supportingEmails: affected,
                    keyEntities: affected.compactMap { $0.headers["From"] },
                    suggestedAngle: "Explore what caused the tone change — potential conflict, bad news, or pressure"
                ))
            }
        }

        let spikes = anomalies.filter { $0.type == .frequencySpike }
        for spike in spikes {
            let affected = emails.filter { spike.affectedEmails.contains($0.id) }
            if affected.count >= 3 {
                let entities = extractEntitiesQuick(from: affected)
                leads.append(StoryLead(
                    id: UUID(),
                    headline: "Communication spike: \(affected.count) emails in burst — \(spike.detail)",
                    relevanceScore: spike.severity,
                    leadType: .patternBreak,
                    supportingEmails: affected,
                    keyEntities: entities,
                    suggestedAngle: "Investigate what event triggered the sudden communication increase"
                ))
            }
        }

        if let graph = graph {
            let unexpectedConnections = findUnexpectedConnections(graph: graph, emails: emails)
            for connection in unexpectedConnections {
                leads.append(StoryLead(
                    id: UUID(),
                    headline: "Unexpected connection: \(connection.personA) ↔ \(connection.personB) via \(connection.linkType)",
                    relevanceScore: connection.unusualness,
                    leadType: .unusualConnection,
                    supportingEmails: connection.evidenceEmails,
                    keyEntities: [connection.personA, connection.personB],
                    suggestedAngle: "Explore the nature of communication between \(connection.personA) and \(connection.personB)"
                ))
            }
        }

        return leads.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    // MARK: - Contradiction Detection

    static func detectContradictions(in emails: [MBOXParser.RawEmail]) -> [Contradiction] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let negationPairs = [
            ("will", "will not"), ("can", "cannot"), ("agree", "disagree"),
            ("approve", "reject"), ("confirm", "deny"), ("increase", "decrease"),
            ("accept", "decline"), ("support", "oppose"), ("allow", "prohibit"),
            ("succeed", "fail"), ("positive", "negative"), ("growth", "decline")
        ]

        struct Claim {
            let sentence: String
            let email: MBOXParser.RawEmail
            let sender: String
            let date: Date?
            let topic: String
        }

        var claims: [Claim] = []

        let sampled = emails.count > 500 ? Array(emails.shuffled().prefix(500)) : emails

        for email in sampled {
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let sender = email.headers["From"] ?? ""
            let date = email.headers["Date"].flatMap { formatter.date(from: $0) }

            let sentences = body.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 20 && $0.count < 300 }

            let assertive = sentences.filter { sentence in
                let lower = sentence.lowercased()
                return lower.contains("will ") || lower.contains("we are ") || lower.contains("i confirm") ||
                       lower.contains("the plan is") || lower.contains("we have decided") ||
                       lower.contains("it is ") || lower.contains("we expect") ||
                       lower.contains("the budget") || lower.contains("the deadline") ||
                       lower.contains("our position") || lower.contains("we agree")
            }

            for sentence in assertive.prefix(3) {
                let topic = extractTopicFromSentence(sentence)
                claims.append(Claim(sentence: sentence, email: email, sender: sender, date: date, topic: topic))
            }
        }

        var contradictions: [Contradiction] = []
        let claimCount = claims.count

        for i in 0..<claimCount {
            for j in (i+1)..<min(claimCount, i + 200) {
                let a = claims[i]
                let b = claims[j]

                guard a.sender != b.sender || (a.date != nil && b.date != nil && abs(a.date!.timeIntervalSince(b.date!)) > 86400) else {
                    continue
                }
                guard !a.topic.isEmpty && a.topic == b.topic else { continue }

                let distance = embedding.distance(between: a.sentence, and: b.sentence, distanceType: .cosine)
                let similarity = 1.0 - distance

                guard similarity > 0.4 && similarity < 0.85 else { continue }

                let hasNegation = negationPairs.contains { pair in
                    (a.sentence.lowercased().contains(pair.0) && b.sentence.lowercased().contains(pair.1)) ||
                    (a.sentence.lowercased().contains(pair.1) && b.sentence.lowercased().contains(pair.0))
                }

                guard hasNegation else { continue }

                contradictions.append(Contradiction(
                    id: UUID(),
                    claimA: .init(email: a.email, sender: a.sender, snippet: String(a.sentence.prefix(200)), date: a.date),
                    claimB: .init(email: b.email, sender: b.sender, snippet: String(b.sentence.prefix(200)), date: b.date),
                    similarity: similarity,
                    topic: a.topic
                ))
            }
        }

        return contradictions.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Quote Extraction

    static func extractQuotes(from emails: [MBOXParser.RawEmail]) -> [ExtractedQuote] {
        var quotes: [ExtractedQuote] = []

        for email in emails {
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let sender = email.headers["From"] ?? ""

            let lines = body.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count > 30 && trimmed.count < 500 else { continue }

                if (trimmed.hasPrefix("\"") && trimmed.dropFirst().contains("\"")) ||
                   (trimmed.hasPrefix("\u{201C}") && trimmed.contains("\u{201D}")) {

                    let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))
                    let newsworthiness = scoreNewsworthiness(cleaned)

                    if newsworthiness > 0.3 {
                        quotes.append(ExtractedQuote(
                            id: UUID(),
                            text: cleaned,
                            speaker: extractDisplayName(from: sender, fallback: sender),
                            email: email,
                            context: email.headers["Subject"] ?? "",
                            newsworthiness: newsworthiness
                        ))
                    }
                }

                let saidPatterns = [" said ", " stated ", " wrote ", " noted ", " commented ", " explained ", " argued ", " claimed "]
                for pattern in saidPatterns {
                    if let range = trimmed.lowercased().range(of: pattern) {
                        let afterVerb = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if afterVerb.count > 20 {
                            let speaker = String(trimmed[..<range.lowerBound])
                            let newsworthiness = scoreNewsworthiness(afterVerb)
                            if newsworthiness > 0.3 && speaker.count < 60 {
                                quotes.append(ExtractedQuote(
                                    id: UUID(),
                                    text: afterVerb.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}.,;:")),
                                    speaker: speaker.isEmpty ? extractDisplayName(from: sender, fallback: sender) : speaker,
                                    email: email,
                                    context: email.headers["Subject"] ?? "",
                                    newsworthiness: newsworthiness
                                ))
                            }
                        }
                    }
                }
            }
        }

        return quotes.sorted { $0.newsworthiness > $1.newsworthiness }
    }

    // MARK: - Timeline Event Extraction

    static func extractTimelineEvents(from emails: [MBOXParser.RawEmail]) -> [TimelineEvent] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let eventKeywords: [(keywords: [String], type: TimelineEvent.EventType)] = [
            (["announce", "announcing", "announcement", "pleased to share", "we are launching", "introducing"], .announcement),
            (["decided", "decision", "approved", "rejected", "voted", "resolved", "we will proceed"], .decision),
            (["meeting", "conference call", "sync", "standup", "all-hands", "town hall", "agenda"], .meeting),
            (["deadline", "due date", "due by", "must be completed", "submission date", "cutoff"], .deadline),
            (["incident", "outage", "breach", "emergency", "critical issue", "severity", "downtime"], .incident)
        ]

        var events: [TimelineEvent] = []
        var seenSubjects: Set<String> = []

        for email in emails {
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { continue }

            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let combined = subject + " " + String(body.prefix(1000))

            let normalizedSubject = subject.replacingOccurrences(of: "re: ", with: "").replacingOccurrences(of: "fwd: ", with: "")
            guard !seenSubjects.contains(normalizedSubject) else { continue }

            for (keywords, eventType) in eventKeywords {
                if keywords.contains(where: { combined.contains($0) }) {
                    seenSubjects.insert(normalizedSubject)

                    let entities = extractEntitiesQuick(from: [email])
                    let summary = (email.headers["Subject"] ?? "Communication") + " — " + extractDisplayName(from: email.headers["From"] ?? "", fallback: "Unknown")

                    events.append(TimelineEvent(
                        id: UUID(),
                        date: date,
                        summary: summary,
                        eventType: eventType,
                        emails: [email],
                        entities: entities
                    ))
                    break
                }
            }
        }

        return events.sorted { $0.date < $1.date }
    }

    // MARK: - Private Helpers

    private static func measureConsistency(emails: [MBOXParser.RawEmail]) -> Double {
        guard emails.count >= 3 else { return 0.5 }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var sentiments: [Double] = []

        for email in emails.prefix(30) {
            let text = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            tagger.string = String(text.prefix(1000))
            if let tag = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0,
               let score = Double(tag.rawValue) {
                sentiments.append(score)
            }
        }

        guard sentiments.count >= 2 else { return 0.5 }

        let mean = sentiments.reduce(0, +) / Double(sentiments.count)
        let variance = sentiments.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(sentiments.count)
        let stdDev = sqrt(variance)

        return max(0, 1.0 - stdDev)
    }

    private static func measureReciprocity(address: String, emails: [MBOXParser.RawEmail], threadMap: [String: [MBOXParser.RawEmail]]) -> Double {
        let sent = emails.filter { extractEmailAddress(from: $0.headers["From"] ?? "") == address }
        let received = emails.filter {
            let to = ($0.headers["To"] ?? "") + "," + ($0.headers["Cc"] ?? "")
            return to.lowercased().contains(address)
        }

        guard sent.count > 0 && received.count > 0 else { return 0.1 }

        let ratio = Double(min(sent.count, received.count)) / Double(max(sent.count, received.count))
        return ratio
    }

    private static func measureTopicDiversity(emails: [MBOXParser.RawEmail]) -> Int {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        var topics: Set<String> = []

        for email in emails.prefix(30) {
            let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
                if tag == .noun {
                    let word = String(text[range]).lowercased()
                    if word.count > 3 {
                        topics.insert(word)
                    }
                }
                return true
            }
        }
        return topics.count
    }

    private static func calculateAvgResponseTime(address: String, dates: [Date], threadMap: [String: [MBOXParser.RawEmail]], emails: [MBOXParser.RawEmail]) -> TimeInterval? {
        guard dates.count >= 2 else { return nil }
        var gaps: [TimeInterval] = []
        for i in 1..<dates.count {
            let gap = dates[i].timeIntervalSince(dates[i-1])
            if gap > 60 && gap < 7 * 86400 {
                gaps.append(gap)
            }
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    private static func buildThreadMap(emails: [MBOXParser.RawEmail]) -> [String: [MBOXParser.RawEmail]] {
        var map: [String: [MBOXParser.RawEmail]] = [:]
        for email in emails {
            let subject = (email.headers["Subject"] ?? "")
                .replacingOccurrences(of: "Re: ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Fwd: ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if !subject.isEmpty {
                map[subject, default: []].append(email)
            }
        }
        return map
    }

    private struct TopicTrend {
        let topic: String
        let historicalCount: Int
        let recentCount: Int
        let growthRate: Double
        let isEmerging: Bool
        let recentEmails: [MBOXParser.RawEmail]
        let relatedEntities: [String]
    }

    private static func detectTopicTrends(emails: [MBOXParser.RawEmail]) -> [TopicTrend] {
        guard emails.count >= 20 else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let dated = emails.compactMap { email -> (MBOXParser.RawEmail, Date)? in
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { return nil }
            return (email, date)
        }.sorted { $0.1 < $1.1 }

        let splitPoint = dated.count * 3 / 4
        let historical = Array(dated.prefix(splitPoint))
        let recent = Array(dated.suffix(dated.count - splitPoint))

        func extractNouns(from emails: [(MBOXParser.RawEmail, Date)]) -> [String: (count: Int, emails: [MBOXParser.RawEmail])] {
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            var result: [String: (count: Int, emails: [MBOXParser.RawEmail])] = [:]
            for (email, _) in emails.prefix(200) {
                let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
                tagger.string = text
                var emailNouns: Set<String> = []
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
                    if tag == .noun {
                        let word = String(text[range]).lowercased()
                        if word.count > 3 { emailNouns.insert(word) }
                    }
                    return true
                }
                for noun in emailNouns {
                    var entry = result[noun, default: (0, [])]
                    entry.count += 1
                    entry.emails.append(email)
                    result[noun] = entry
                }
            }
            return result
        }

        let historicalTopics = extractNouns(from: historical)
        let recentTopics = extractNouns(from: recent)

        var trends: [TopicTrend] = []
        for (topic, recentData) in recentTopics {
            let historicalCount = historicalTopics[topic]?.count ?? 0
            let recentCount = recentData.count
            guard recentCount >= 3 else { continue }

            let normalizedHistorical = Double(historicalCount) / max(1.0, Double(historical.count)) * Double(recent.count)
            let growthRate: Double
            if normalizedHistorical < 0.5 {
                growthRate = min(1.0, Double(recentCount) / 5.0)
            } else {
                growthRate = min(1.0, (Double(recentCount) - normalizedHistorical) / normalizedHistorical)
            }

            if growthRate > 0.3 {
                let entities = extractEntitiesQuick(from: recentData.emails)
                trends.append(TopicTrend(
                    topic: topic,
                    historicalCount: historicalCount,
                    recentCount: recentCount,
                    growthRate: growthRate,
                    isEmerging: true,
                    recentEmails: Array(recentData.emails.prefix(5)),
                    relatedEntities: entities
                ))
            }
        }

        return trends.sorted { $0.growthRate > $1.growthRate }.prefix(10).map { $0 }
    }

    private struct UnexpectedConnection {
        let personA: String
        let personB: String
        let linkType: String
        let unusualness: Double
        let evidenceEmails: [MBOXParser.RawEmail]
    }

    private static func findUnexpectedConnections(graph: KnowledgeGraph, emails: [MBOXParser.RawEmail]) -> [UnexpectedConnection] {
        let people = graph.topNodes(by: .person, limit: 30)
        var connections: [UnexpectedConnection] = []

        for i in 0..<people.count {
            for j in (i+1)..<people.count {
                let a = people[i]
                let b = people[j]

                let edges = graph.edgesBetween(a.id, b.id)
                guard !edges.isEmpty else { continue }

                let aDomain = a.properties["email"].flatMap { extractDomainFromAddress($0) } ?? ""
                let bDomain = b.properties["email"].flatMap { extractDomainFromAddress($0) } ?? ""

                let crossDomain = !aDomain.isEmpty && !bDomain.isEmpty && aDomain != bDomain
                let lowWeight = edges.reduce(0.0) { $0 + $1.weight } < 3.0

                if crossDomain && lowWeight {
                    let evidenceIDs = Set(edges.compactMap { $0.properties["emailID"] })
                    let evidence = emails.filter { evidenceIDs.contains($0.id.uuidString) }.prefix(3)

                    connections.append(UnexpectedConnection(
                        personA: a.label,
                        personB: b.label,
                        linkType: edges.first?.type.rawValue ?? "unknown",
                        unusualness: min(1.0, 1.0 / max(0.1, edges.reduce(0.0) { $0 + $1.weight })),
                        evidenceEmails: Array(evidence)
                    ))
                }
            }
        }

        return connections.sorted { $0.unusualness > $1.unusualness }.prefix(5).map { $0 }
    }

    private static func extractTopicFromSentence(_ sentence: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let text = String(sentence.prefix(200))
        tagger.string = text
        var nouns: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun {
                let word = String(text[range]).lowercased()
                if word.count > 3 { nouns.append(word) }
            }
            return true
        }
        return nouns.first ?? ""
    }

    private static func extractEntitiesQuick(from emails: [MBOXParser.RawEmail]) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        var entities: Set<String> = []
        for email in emails.prefix(10) {
            let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
                if tag == .personalName || tag == .organizationName {
                    entities.insert(String(text[range]))
                }
                return true
            }
        }
        return Array(entities.prefix(10))
    }

    private static func scoreNewsworthiness(_ text: String) -> Double {
        let lower = text.lowercased()
        var score: Double = 0.2

        let impactWords = ["million", "billion", "percent", "government", "investigation",
                           "resign", "fired", "lawsuit", "settlement", "arrest",
                           "violation", "whistleblower", "leak", "corruption", "fraud"]
        for word in impactWords where lower.contains(word) {
            score += 0.15
        }

        let actionWords = ["will", "must", "should", "plan to", "intend to", "decided"]
        for word in actionWords where lower.contains(word) {
            score += 0.05
        }

        if text.contains(where: { $0.isNumber }) { score += 0.1 }

        return min(1.0, score)
    }

    private static func extractEmailAddress(from text: String) -> String {
        if let start = text.range(of: "<"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func extractDisplayName(from header: String, fallback: String) -> String {
        if let angleBracket = header.range(of: "<") {
            let name = String(header[header.startIndex..<angleBracket.lowerBound]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? fallback : name
        }
        return fallback
    }

    private static func extractDomainFromAddress(_ address: String) -> String? {
        guard let atIndex = address.range(of: "@") else { return nil }
        return String(address[atIndex.upperBound...]).lowercased()
    }
}
