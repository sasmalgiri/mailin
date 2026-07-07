import Foundation
import NaturalLanguage

struct ArchiveInsightsFeatures {

    // MARK: - Types

    struct TrendAnalysis: Identifiable {
        let id: String
        let trendType: TrendType
        let title: String
        let detail: String
        let direction: TrendDirection
        let magnitude: Double
        let dataPoints: [(label: String, value: Double)]

        enum TrendType: String, CaseIterable {
            case volume = "Volume"
            case sentiment = "Sentiment"
            case topicShift = "Topic Shift"
            case networkGrowth = "Network Growth"
            case activityPattern = "Activity Pattern"
        }

        enum TrendDirection: String {
            case increasing = "Increasing"
            case decreasing = "Decreasing"
            case stable = "Stable"
            case volatile = "Volatile"
        }
    }

    struct ArchiveComposition: Identifiable {
        let id = "composition"
        let totalEmails: Int
        let dateRange: (earliest: Date?, latest: Date?)
        let uniqueSenders: Int
        let uniqueDomains: Int
        let categories: [(category: String, count: Int, percentage: Double)]
        let languageBreakdown: [(language: String, percentage: Double)]
        let avgEmailLength: Int
        let attachmentRate: Double
        let threadRate: Double
        let qualityScore: Double
        let qualityFactors: [QualityFactor]

        struct QualityFactor {
            let name: String
            let score: Double
            let detail: String
        }
    }

    struct CommunicationPattern: Identifiable {
        let id: String
        let patternType: PatternType
        let title: String
        let detail: String
        let significance: Double
        let participants: [String]
        let timeRange: String

        enum PatternType: String, CaseIterable {
            case cluster = "Communication Cluster"
            case hub = "Hub Person"
            case bridge = "Bridge Connector"
            case isolate = "Isolated Group"
            case burst = "Activity Burst"
            case routine = "Routine Pattern"
        }
    }

    // MARK: - Trend Detection

    static func detectTrends(in emails: [MBOXParser.RawEmail]) -> [TrendAnalysis] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let dated = emails.compactMap { email -> (MBOXParser.RawEmail, Date)? in
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { return nil }
            return (email, date)
        }.sorted { $0.1 < $1.1 }

        guard dated.count >= 10 else { return [] }

        var trends: [TrendAnalysis] = []

        let volumeTrend = analyzeVolumeTrend(dated: dated)
        if let vt = volumeTrend { trends.append(vt) }

        let sentimentTrend = analyzeSentimentTrend(dated: dated)
        if let st = sentimentTrend { trends.append(st) }

        let topicTrend = analyzeTopicShift(dated: dated)
        if let tt = topicTrend { trends.append(tt) }

        let networkTrend = analyzeNetworkGrowth(dated: dated)
        if let nt = networkTrend { trends.append(nt) }

        let activityTrend = analyzeActivityPattern(dated: dated)
        if let at = activityTrend { trends.append(at) }

        return trends
    }

    private static func analyzeVolumeTrend(dated: [(MBOXParser.RawEmail, Date)]) -> TrendAnalysis? {
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        var monthly: [(label: String, date: Date, count: Int)] = []
        var currentMonth: DateComponents?
        var currentCount = 0
        var currentLabel = ""
        var currentDate = Date()

        for (_, date) in dated {
            let comps = calendar.dateComponents([.year, .month], from: date)
            if comps != currentMonth {
                if currentMonth != nil {
                    monthly.append((currentLabel, currentDate, currentCount))
                }
                currentMonth = comps
                currentCount = 0
                currentLabel = monthFormatter.string(from: date)
                currentDate = date
            }
            currentCount += 1
        }
        if currentCount > 0 {
            monthly.append((currentLabel, currentDate, currentCount))
        }

        guard monthly.count >= 3 else { return nil }

        let values = monthly.map { Double($0.count) }
        let (direction, magnitude) = calculateTrend(values: values)

        let recentAvg = values.suffix(3).reduce(0, +) / 3.0
        let olderAvg = values.prefix(max(1, values.count - 3)).reduce(0, +) / Double(max(1, values.count - 3))
        let changePercent = olderAvg > 0 ? (recentAvg - olderAvg) / olderAvg * 100 : 0

        return TrendAnalysis(
            id: "volume_trend",
            trendType: .volume,
            title: "Email Volume \(direction.rawValue)",
            detail: "Average recent volume: \(Int(recentAvg))/month (\(changePercent > 0 ? "+" : "")\(Int(changePercent))% vs earlier period)",
            direction: direction,
            magnitude: magnitude,
            dataPoints: monthly.map { ($0.label, Double($0.count)) }
        )
    }

    private static func analyzeSentimentTrend(dated: [(MBOXParser.RawEmail, Date)]) -> TrendAnalysis? {
        guard dated.count >= 20 else { return nil }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        var monthSentiments: [String: [Double]] = [:]

        for (email, date) in dated.prefix(500) {
            let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
            tagger.string = text
            if let tag = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0,
               let score = Double(tag.rawValue) {
                let key = monthFormatter.string(from: date)
                monthSentiments[key, default: []].append(score)
            }
        }

        let sorted = monthSentiments.sorted { pair1, pair2 in
            let df = DateFormatter()
            df.dateFormat = "MMM yyyy"
            let d1 = df.date(from: pair1.key) ?? Date.distantPast
            let d2 = df.date(from: pair2.key) ?? Date.distantPast
            return d1 < d2
        }

        guard sorted.count >= 3 else { return nil }

        let averages = sorted.map { (label: $0.key, avg: $0.value.reduce(0, +) / Double(max(1, $0.value.count))) }
        let values = averages.map { $0.avg }
        let (direction, magnitude) = calculateTrend(values: values)

        let currentSentiment = values.last ?? 0
        let label = currentSentiment > 0.2 ? "positive" : (currentSentiment < -0.2 ? "negative" : "neutral")

        return TrendAnalysis(
            id: "sentiment_trend",
            trendType: .sentiment,
            title: "Sentiment Trend: \(direction.rawValue)",
            detail: "Overall tone is \(label) (score: \(String(format: "%.2f", currentSentiment))). " +
                    "Trend is \(direction.rawValue.lowercased()) over \(sorted.count) months.",
            direction: direction,
            magnitude: magnitude,
            dataPoints: averages.map { ($0.label, $0.avg) }
        )
    }

    private static func analyzeTopicShift(dated: [(MBOXParser.RawEmail, Date)]) -> TrendAnalysis? {
        guard dated.count >= 30 else { return nil }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let midpoint = dated.count / 2

        func topNouns(from emails: ArraySlice<(MBOXParser.RawEmail, Date)>) -> [String: Int] {
            var counts: [String: Int] = [:]
            for (email, _) in emails.prefix(200) {
                let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
                tagger.string = text
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
                    if tag == .noun {
                        let word = String(text[range]).lowercased()
                        if word.count > 3 { counts[word, default: 0] += 1 }
                    }
                    return true
                }
            }
            return counts
        }

        let earlierTopics = topNouns(from: dated.prefix(midpoint)[...])
        let laterTopics = topNouns(from: dated.suffix(dated.count - midpoint)[...])

        let earlierTop = Set(earlierTopics.sorted { $0.value > $1.value }.prefix(20).map { $0.key })
        let laterTop = Set(laterTopics.sorted { $0.value > $1.value }.prefix(20).map { $0.key })

        let newTopics = laterTop.subtracting(earlierTop)
        let lostTopics = earlierTop.subtracting(laterTop)

        guard !newTopics.isEmpty || !lostTopics.isEmpty else { return nil }

        let shiftMagnitude = Double(newTopics.count + lostTopics.count) / Double(max(1, earlierTop.count + laterTop.count))

        var detail = ""
        if !newTopics.isEmpty {
            detail += "Emerging: \(newTopics.prefix(5).joined(separator: ", ")). "
        }
        if !lostTopics.isEmpty {
            detail += "Fading: \(lostTopics.prefix(5).joined(separator: ", "))."
        }

        return TrendAnalysis(
            id: "topic_shift",
            trendType: .topicShift,
            title: "Topic Evolution Detected",
            detail: detail,
            direction: shiftMagnitude > 0.4 ? .volatile : .stable,
            magnitude: shiftMagnitude,
            dataPoints: newTopics.prefix(5).map { ($0, Double(laterTopics[$0] ?? 0)) }
        )
    }

    private static func analyzeNetworkGrowth(dated: [(MBOXParser.RawEmail, Date)]) -> TrendAnalysis? {
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM yyyy"

        var cumulativeDomains: Set<String> = []
        var monthlyNew: [(label: String, newCount: Int)] = []
        var currentMonth: DateComponents?
        var monthNewDomains = 0
        var currentLabel = ""

        for (email, date) in dated {
            let comps = calendar.dateComponents([.year, .month], from: date)
            if comps != currentMonth {
                if currentMonth != nil {
                    monthlyNew.append((currentLabel, monthNewDomains))
                }
                currentMonth = comps
                monthNewDomains = 0
                currentLabel = monthFormatter.string(from: date)
            }

            let from = email.headers["From"] ?? ""
            if let domain = extractDomain(from: from), !domain.isEmpty {
                if !cumulativeDomains.contains(domain) {
                    cumulativeDomains.insert(domain)
                    monthNewDomains += 1
                }
            }
        }
        if monthNewDomains > 0 {
            monthlyNew.append((currentLabel, monthNewDomains))
        }

        guard monthlyNew.count >= 3 else { return nil }

        let values = monthlyNew.map { Double($0.newCount) }
        let (direction, magnitude) = calculateTrend(values: values)

        return TrendAnalysis(
            id: "network_growth",
            trendType: .networkGrowth,
            title: "Contact Network \(direction.rawValue)",
            detail: "\(cumulativeDomains.count) unique domains total. New domain discovery rate is \(direction.rawValue.lowercased()).",
            direction: direction,
            magnitude: magnitude,
            dataPoints: monthlyNew.map { ($0.label, Double($0.newCount)) }
        )
    }

    private static func analyzeActivityPattern(dated: [(MBOXParser.RawEmail, Date)]) -> TrendAnalysis? {
        let calendar = Calendar.current
        var hourCounts = [Int](repeating: 0, count: 24)

        for (_, date) in dated {
            let hour = calendar.component(.hour, from: date)
            hourCounts[hour] += 1
        }

        let total = Double(hourCounts.reduce(0, +))
        guard total > 0 else { return nil }

        let businessHours = hourCounts[9...17].reduce(0, +)
        let evening = hourCounts[18...22].reduce(0, +)

        let businessPct = Double(businessHours) / total
        let eveningPct = Double(evening) / total

        let pattern: String
        let direction: TrendAnalysis.TrendDirection
        if businessPct > 0.7 {
            pattern = "Strongly business-hours focused (\(Int(businessPct * 100))% during 9am-5pm)"
            direction = .stable
        } else if eveningPct > 0.3 {
            pattern = "Significant evening activity (\(Int(eveningPct * 100))% after 6pm)"
            direction = .volatile
        } else {
            pattern = "Distributed across the day (business: \(Int(businessPct * 100))%, evening: \(Int(eveningPct * 100))%)"
            direction = .stable
        }

        return TrendAnalysis(
            id: "activity_pattern",
            trendType: .activityPattern,
            title: "Activity Distribution",
            detail: pattern,
            direction: direction,
            magnitude: businessPct,
            dataPoints: (0..<24).map { hour in
                let label = hour < 12 ? "\(hour == 0 ? 12 : hour)am" : "\(hour == 12 ? 12 : hour - 12)pm"
                return (label, Double(hourCounts[hour]))
            }
        )
    }

    // MARK: - Archive Composition Analysis

    static func analyzeComposition(emails: [MBOXParser.RawEmail]) -> ArchiveComposition {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var senders: Set<String> = []
        var domains: Set<String> = []
        var dates: [Date] = []
        var totalBodyLength = 0
        var withAttachments = 0
        var withReplyTo = 0

        for email in emails {
            let from = email.headers["From"] ?? ""
            senders.insert(extractEmailAddress(from: from))
            if let domain = extractDomain(from: from) { domains.insert(domain) }
            if let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) {
                dates.append(date)
            }
            totalBodyLength += (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).count
            if !email.attachments.isEmpty { withAttachments += 1 }
            if email.headers["In-Reply-To"] != nil || email.inReplyTo != nil { withReplyTo += 1 }
        }

        let classifications = EmailNLPEngine.classifyAll(emails)
        let categories = classifications.sorted { $0.value > $1.value }.map { cat -> (String, Int, Double) in
            (cat.key.rawValue, cat.value, Double(cat.value) / Double(max(1, emails.count)) * 100)
        }

        let languages = EmailNLPEngine.detectLanguages(in: Array(emails.prefix(200)))
        let langBreakdown = languages.map { ($0.language, $0.percentage) }

        let avgLength = emails.isEmpty ? 0 : totalBodyLength / emails.count
        let attachmentRate = emails.isEmpty ? 0 : Double(withAttachments) / Double(emails.count)
        let threadRate = emails.isEmpty ? 0 : Double(withReplyTo) / Double(emails.count)

        var qualityFactors: [ArchiveComposition.QualityFactor] = []
        var qualityScore: Double = 0.5

        let diversityScore = min(1.0, Double(senders.count) / Double(max(1, emails.count / 5)))
        qualityFactors.append(.init(name: "Sender Diversity", score: diversityScore, detail: "\(senders.count) unique senders across \(emails.count) emails"))
        qualityScore += diversityScore * 0.15

        let completeness: Double
        let datedRatio = Double(dates.count) / Double(max(1, emails.count))
        completeness = datedRatio
        qualityFactors.append(.init(name: "Date Completeness", score: completeness, detail: "\(Int(datedRatio * 100))% of emails have parseable dates"))
        qualityScore += completeness * 0.15

        let bodyScore: Double = avgLength > 50 ? min(1.0, Double(avgLength) / 500.0) : 0.2
        qualityFactors.append(.init(name: "Content Richness", score: bodyScore, detail: "Average email length: \(avgLength) characters"))
        qualityScore += bodyScore * 0.1

        qualityFactors.append(.init(name: "Thread Depth", score: threadRate, detail: "\(Int(threadRate * 100))% of emails are threaded"))
        qualityScore += threadRate * 0.1

        let sortedDates = dates.sorted()

        return ArchiveComposition(
            totalEmails: emails.count,
            dateRange: (sortedDates.first, sortedDates.last),
            uniqueSenders: senders.count,
            uniqueDomains: domains.count,
            categories: categories,
            languageBreakdown: langBreakdown,
            avgEmailLength: avgLength,
            attachmentRate: attachmentRate,
            threadRate: threadRate,
            qualityScore: min(1.0, qualityScore),
            qualityFactors: qualityFactors
        )
    }

    // MARK: - Communication Pattern Analysis

    static func analyzeCommunicationPatterns(
        emails: [MBOXParser.RawEmail],
        graph: KnowledgeGraph? = nil
    ) -> [CommunicationPattern] {
        var patterns: [CommunicationPattern] = []

        let hubs = findCommunicationHubs(emails: emails)
        patterns.append(contentsOf: hubs)

        let bursts = findActivityBursts(emails: emails)
        patterns.append(contentsOf: bursts)

        let routines = findRoutinePatterns(emails: emails)
        patterns.append(contentsOf: routines)

        if let graph = graph {
            let bridges = findBridgeConnectors(graph: graph)
            patterns.append(contentsOf: bridges)
        }

        return patterns.sorted { $0.significance > $1.significance }
    }

    private static func findCommunicationHubs(emails: [MBOXParser.RawEmail]) -> [CommunicationPattern] {
        var senderRecipientPairs: [String: Set<String>] = [:]

        for email in emails {
            let from = extractEmailAddress(from: email.headers["From"] ?? "")
            guard !from.isEmpty else { continue }

            let recipients = extractAllRecipients(from: email)
            senderRecipientPairs[from, default: Set()].formUnion(recipients)
        }

        return senderRecipientPairs.compactMap { sender, recipients -> CommunicationPattern? in
            guard recipients.count >= 10 else { return nil }

            return CommunicationPattern(
                id: "hub-\(sender)",
                patternType: .hub,
                title: "Communication Hub: \(extractDisplayName(from: sender))",
                detail: "Connected to \(recipients.count) unique contacts — central to information flow",
                significance: min(1.0, Double(recipients.count) / 30.0),
                participants: [sender] + Array(recipients.prefix(5)),
                timeRange: ""
            )
        }.sorted { $0.significance > $1.significance }.prefix(5).map { $0 }
    }

    private static func findActivityBursts(emails: [MBOXParser.RawEmail]) -> [CommunicationPattern] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d, yyyy"

        var dailyCounts: [String: (count: Int, emails: [MBOXParser.RawEmail], date: Date)] = [:]

        for email in emails {
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { continue }
            let dayKey = dayFormatter.string(from: date)
            var entry = dailyCounts[dayKey, default: (0, [], date)]
            entry.count += 1
            entry.emails.append(email)
            dailyCounts[dayKey] = entry
        }

        let counts = dailyCounts.values.map { Double($0.count) }
        guard counts.count >= 7 else { return [] }
        let mean = counts.reduce(0, +) / Double(counts.count)
        let threshold = mean * 3

        return dailyCounts.compactMap { dayKey, data -> CommunicationPattern? in
            guard Double(data.count) > threshold else { return nil }

            let participants = Array(Set(data.emails.compactMap { $0.headers["From"] }).prefix(5))

            return CommunicationPattern(
                id: "burst-\(dayKey)",
                patternType: .burst,
                title: "Activity Burst on \(dayKey)",
                detail: "\(data.count) emails (normal: ~\(Int(mean))/day) — \(Int(Double(data.count) / mean))x above average",
                significance: min(1.0, (Double(data.count) - mean) / (mean * 3)),
                participants: participants,
                timeRange: dayKey
            )
        }.sorted { $0.significance > $1.significance }.prefix(5).map { $0 }
    }

    private static func findRoutinePatterns(emails: [MBOXParser.RawEmail]) -> [CommunicationPattern] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let calendar = Calendar.current

        var subjectCounts: [String: (count: Int, senders: Set<String>, days: Set<Int>)] = [:]

        for email in emails {
            let subject = (email.headers["Subject"] ?? "")
                .replacingOccurrences(of: "Re: ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Fwd: ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            guard !subject.isEmpty && subject.count > 3 else { continue }

            let from = email.headers["From"] ?? ""
            let weekday = email.headers["Date"].flatMap { formatter.date(from: $0) }.map { calendar.component(.weekday, from: $0) }

            var entry = subjectCounts[subject, default: (0, Set(), Set())]
            entry.count += 1
            entry.senders.insert(from)
            if let wd = weekday { entry.days.insert(wd) }
            subjectCounts[subject] = entry
        }

        return subjectCounts.compactMap { subject, data -> CommunicationPattern? in
            guard data.count >= 4 else { return nil }

            let isRoutine = data.days.count <= 2 && data.count >= 4
            guard isRoutine || data.count >= 8 else { return nil }

            let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let routineDays = data.days.sorted().map { dayNames[$0] }.joined(separator: ", ")

            return CommunicationPattern(
                id: "routine-\(subject.prefix(30))",
                patternType: .routine,
                title: "Recurring: \(subject.prefix(50))",
                detail: "\(data.count) occurrences from \(data.senders.count) sender(s)" + (routineDays.isEmpty ? "" : " — typically on \(routineDays)"),
                significance: min(1.0, Double(data.count) / 20.0),
                participants: Array(data.senders.prefix(3)),
                timeRange: routineDays
            )
        }.sorted { $0.significance > $1.significance }.prefix(5).map { $0 }
    }

    private static func findBridgeConnectors(graph: KnowledgeGraph) -> [CommunicationPattern] {
        let people = graph.findNodes(type: .person)
        var bridges: [CommunicationPattern] = []

        for person in people.prefix(50) {
            let neighbors = graph.neighbors(of: person.id)
            guard neighbors.count >= 3 else { continue }

            var groupDomains: [String: [KGNode]] = [:]
            for neighbor in neighbors {
                if let email = neighbor.properties["email"], let domain = email.components(separatedBy: "@").last {
                    groupDomains[domain, default: []].append(neighbor)
                }
            }

            let connectedDomains = groupDomains.filter { $0.value.count >= 2 }
            if connectedDomains.count >= 3 {
                bridges.append(CommunicationPattern(
                    id: "bridge-\(person.id)",
                    patternType: .bridge,
                    title: "Bridge: \(person.label)",
                    detail: "Connects \(connectedDomains.count) different organizations with \(neighbors.count) total contacts",
                    significance: min(1.0, Double(connectedDomains.count) / 5.0),
                    participants: [person.label] + neighbors.prefix(4).map(\.label),
                    timeRange: ""
                ))
            }
        }

        return bridges.sorted { $0.significance > $1.significance }.prefix(3).map { $0 }
    }

    // MARK: - Helpers

    private static func calculateTrend(values: [Double]) -> (TrendAnalysis.TrendDirection, Double) {
        guard values.count >= 3 else { return (.stable, 0) }

        let n = Double(values.count)
        let xMean = (n - 1) / 2
        let yMean = values.reduce(0, +) / n

        var numerator: Double = 0
        var denominator: Double = 0
        for (i, y) in values.enumerated() {
            let x = Double(i)
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        guard denominator > 0 else { return (.stable, 0) }
        let slope = numerator / denominator
        let normalizedSlope = slope / max(1, yMean)

        let direction: TrendAnalysis.TrendDirection
        if normalizedSlope > 0.1 { direction = .increasing }
        else if normalizedSlope < -0.1 { direction = .decreasing }
        else {
            let variance = values.map { ($0 - yMean) * ($0 - yMean) }.reduce(0, +) / n
            let cv = sqrt(variance) / max(1, yMean)
            direction = cv > 0.5 ? .volatile : .stable
        }

        return (direction, abs(normalizedSlope))
    }

    private static func extractEmailAddress(from text: String) -> String {
        if let start = text.range(of: "<"), let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func extractDomain(from text: String) -> String? {
        let address = extractEmailAddress(from: text)
        guard let atIndex = address.range(of: "@") else { return nil }
        return String(address[atIndex.upperBound...]).lowercased()
    }

    private static func extractDisplayName(from address: String) -> String {
        if let angleBracket = address.range(of: "<") {
            let name = String(address[address.startIndex..<angleBracket.lowerBound]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? address : name
        }
        return address
    }

    private static func extractAllRecipients(from email: MBOXParser.RawEmail) -> [String] {
        let to = email.headers["To"] ?? ""
        let cc = email.headers["Cc"] ?? ""
        return (to + "," + cc).components(separatedBy: ",").compactMap { part in
            let addr = extractEmailAddress(from: part)
            return addr.contains("@") ? addr : nil
        }
    }
}
