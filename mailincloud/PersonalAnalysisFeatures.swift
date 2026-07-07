import Foundation
import NaturalLanguage

struct PersonalAnalysisFeatures {

    // MARK: - Types

    struct ActionItem: Identifiable {
        let id: UUID
        let text: String
        let email: MBOXParser.RawEmail
        let sender: String
        let deadline: Date?
        let urgency: Urgency
        let actionType: ActionType

        enum Urgency: String, CaseIterable, Comparable {
            case immediate = "Immediate"
            case today = "Today"
            case thisWeek = "This Week"
            case someday = "Someday"

            static func < (lhs: Urgency, rhs: Urgency) -> Bool {
                let order: [Urgency] = [.someday, .thisWeek, .today, .immediate]
                return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
            }
        }

        enum ActionType: String {
            case reply = "Reply Needed"
            case task = "Task"
            case decision = "Decision"
            case payment = "Payment"
            case appointment = "Appointment"
            case followUp = "Follow Up"
        }
    }

    struct Subscription: Identifiable {
        let id: String
        let senderDomain: String
        let senderName: String
        let emailCount: Int
        let category: SubscriptionCategory
        let frequency: SubscriptionFrequency
        let hasUnsubscribe: Bool
        let lastReceived: Date?
        let readEngagement: Double

        enum SubscriptionCategory: String, CaseIterable {
            case newsletter = "Newsletter"
            case promotional = "Promotional"
            case socialMedia = "Social Media"
            case transactional = "Transactional"
            case notification = "Notification"
            case unknown = "Unknown"
        }

        enum SubscriptionFrequency: String {
            case daily = "Daily"
            case weekly = "Weekly"
            case monthly = "Monthly"
            case irregular = "Irregular"
        }
    }

    struct ContactRelationship: Identifiable {
        let id: String
        let name: String
        let email: String
        let importanceScore: Double
        let frequency: Int
        let reciprocity: Double
        let recency: Date?
        let avgSentiment: Double
        let topTopics: [String]
        let relationship: RelationshipType

        enum RelationshipType: String {
            case close = "Close"
            case regular = "Regular"
            case acquaintance = "Acquaintance"
            case oneWay = "One-Way"
            case dormant = "Dormant"
        }
    }

    struct ResponseUrgency: Identifiable {
        let id: UUID
        let email: MBOXParser.RawEmail
        let urgencyScore: Double
        let reasons: [String]
        let suggestedResponseTime: String
    }

    struct EmailHabitInsight: Identifiable {
        let id: String
        let title: String
        let detail: String
        let metric: String
        let category: InsightCategory

        enum InsightCategory: String {
            case timing = "Timing"
            case volume = "Volume"
            case responsiveness = "Responsiveness"
            case organization = "Organization"
        }
    }

    // MARK: - Action Item Extraction

    private static let actionPatterns: [(pattern: String, type: ActionItem.ActionType, urgencyBoost: Double)] = [
        ("can you", .reply, 0),
        ("could you", .reply, 0),
        ("would you", .reply, 0),
        ("please reply", .reply, 0.2),
        ("please respond", .reply, 0.2),
        ("let me know", .reply, 0),
        ("get back to me", .reply, 0.1),
        ("rsvp", .reply, 0.3),
        ("need your input", .reply, 0.2),
        ("need your approval", .decision, 0.3),
        ("please approve", .decision, 0.3),
        ("please confirm", .decision, 0.2),
        ("please review", .task, 0.1),
        ("please send", .task, 0.1),
        ("please update", .task, 0.1),
        ("please complete", .task, 0.2),
        ("please submit", .task, 0.2),
        ("action required", .task, 0.4),
        ("action needed", .task, 0.3),
        ("to-do", .task, 0.1),
        ("todo", .task, 0.1),
        ("follow up", .followUp, 0.1),
        ("following up", .followUp, 0.1),
        ("reminder", .followUp, 0.2),
        ("don't forget", .followUp, 0.2),
        ("payment due", .payment, 0.3),
        ("invoice", .payment, 0.1),
        ("amount due", .payment, 0.3),
        ("balance due", .payment, 0.3),
        ("scheduled for", .appointment, 0.1),
        ("meeting on", .appointment, 0.1),
        ("appointment", .appointment, 0.1),
        ("calendar invite", .appointment, 0.2)
    ]

    static func extractActionItems(from emails: [MBOXParser.RawEmail]) -> [ActionItem] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var items: [ActionItem] = []

        for email in emails {
            let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
            let bodyLower = body.lowercased()
            let sender = email.headers["From"] ?? ""
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let emailDate = email.headers["Date"].flatMap { formatter.date(from: $0) }

            var bestMatch: (pattern: String, type: ActionItem.ActionType, urgencyBoost: Double)?

            for ap in actionPatterns {
                if bodyLower.contains(ap.pattern) || subject.contains(ap.pattern) {
                    if bestMatch == nil || ap.urgencyBoost > bestMatch!.urgencyBoost {
                        bestMatch = ap
                    }
                }
            }

            guard let match = bestMatch else { continue }

            let deadline = extractDeadline(from: body, relativeTo: emailDate)
            let urgency = determineUrgency(body: bodyLower, subject: subject, deadline: deadline, emailDate: emailDate, boost: match.urgencyBoost)

            let snippet = extractActionSnippet(containing: match.pattern, from: body)

            items.append(ActionItem(
                id: email.id,
                text: snippet,
                email: email,
                sender: extractDisplayName(from: sender, fallback: sender),
                deadline: deadline,
                urgency: urgency,
                actionType: match.type
            ))
        }

        return items.sorted { $0.urgency > $1.urgency }
    }

    private static func determineUrgency(body: String, subject: String, deadline: Date?, emailDate: Date?, boost: Double) -> ActionItem.Urgency {
        var score: Double = boost

        let urgentWords = ["urgent", "asap", "immediately", "right away", "critical", "emergency", "time-sensitive"]
        for word in urgentWords where body.contains(word) || subject.contains(word) {
            score += 0.4
            break
        }

        let todayWords = ["today", "eod", "end of day", "by close of business", "cob", "this afternoon"]
        for word in todayWords where body.contains(word) || subject.contains(word) {
            score += 0.3
            break
        }

        if let deadline = deadline {
            let hoursUntil = deadline.timeIntervalSinceNow / 3600
            if hoursUntil < 4 { score += 0.5 }
            else if hoursUntil < 24 { score += 0.3 }
            else if hoursUntil < 168 { score += 0.1 }
        }

        if let emailDate = emailDate {
            let age = Date().timeIntervalSince(emailDate) / 86400
            if age > 7 { score -= 0.1 }
            if age > 30 { score -= 0.2 }
        }

        switch score {
        case 0.6...: return .immediate
        case 0.35..<0.6: return .today
        case 0.15..<0.35: return .thisWeek
        default: return .someday
        }
    }

    private static func extractDeadline(from text: String, relativeTo baseDate: Date?) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current
        let base = baseDate ?? Date()

        if lower.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: base)
        }
        if lower.contains("next week") {
            return calendar.date(byAdding: .weekOfYear, value: 1, to: base)
        }
        if lower.contains("end of week") || lower.contains("by friday") {
            var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: base)
            comps.weekday = 6
            return calendar.date(from: comps)
        }
        if lower.contains("end of month") {
            guard let range = calendar.range(of: .day, in: .month, for: base) else { return nil }
            var comps = calendar.dateComponents([.year, .month], from: base)
            comps.day = range.count
            return calendar.date(from: comps)
        }

        let pattern = #"(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MM/dd/yyyy"
            let dateStr = String(text[Range(match.range, in: text)!])
            return dateFormatter.date(from: dateStr)
        }

        return nil
    }

    // MARK: - Subscription Detection

    private static let knownMailingPlatforms = [
        "mailchimp.com", "sendgrid.net", "amazonses.com", "constantcontact.com",
        "hubspot.com", "mailgun.org", "sparkpostmail.com", "em.mailjet.com",
        "cmail19.com", "cmail20.com", "createsend.com", "mcsv.net",
        "substack.com", "beehiiv.com", "convertkit.com", "drip.com"
    ]

    private static let socialMediaDomains = [
        "facebookmail.com", "linkedin.com", "twitter.com", "x.com",
        "instagram.com", "pinterest.com", "reddit.com", "tiktok.com",
        "youtube.com", "discord.com", "slack.com", "medium.com"
    ]

    static func detectSubscriptions(in emails: [MBOXParser.RawEmail]) -> [Subscription] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var domainGroups: [String: [MBOXParser.RawEmail]] = [:]

        for email in emails {
            let from = email.headers["From"] ?? ""
            guard let domain = extractDomain(from: from), !domain.isEmpty else { continue }
            domainGroups[domain, default: []].append(email)
        }

        return domainGroups.compactMap { domain, emails -> Subscription? in
            guard emails.count >= 2 else { return nil }

            let hasListHeaders = emails.contains { email in
                email.headers["List-Unsubscribe"] != nil ||
                email.headers["List-Id"] != nil ||
                email.headers["Precedence"]?.lowercased() == "bulk" ||
                email.headers["Precedence"]?.lowercased() == "list"
            }

            let hasUnsubscribe = emails.contains {
                $0.headers["List-Unsubscribe"] != nil ||
                ($0.plainBody + $0.htmlBody).lowercased().contains("unsubscribe")
            }

            let isFromPlatform = knownMailingPlatforms.contains(where: { platform in
                emails.contains { ($0.headers["Received"] ?? "").lowercased().contains(platform) ||
                    ($0.headers["X-Mailer"] ?? "").lowercased().contains(platform) }
            })

            let isSocialMedia = socialMediaDomains.contains(domain)

            guard hasListHeaders || hasUnsubscribe || isFromPlatform || isSocialMedia || emails.count >= 5 else { return nil }

            let category: Subscription.SubscriptionCategory
            if isSocialMedia {
                category = .socialMedia
            } else if hasListHeaders && !hasUnsubscribe {
                category = .notification
            } else {
                let sampleBody = emails.first.map { ($0.plainBody.isEmpty ? $0.htmlBody : $0.plainBody).lowercased() } ?? ""
                if sampleBody.contains("sale") || sampleBody.contains("% off") || sampleBody.contains("discount") || sampleBody.contains("promo") {
                    category = .promotional
                } else if sampleBody.contains("order") || sampleBody.contains("receipt") || sampleBody.contains("invoice") || sampleBody.contains("shipping") {
                    category = .transactional
                } else if hasListHeaders || isFromPlatform {
                    category = .newsletter
                } else {
                    category = .unknown
                }
            }

            let dates = emails.compactMap { email -> Date? in
                email.headers["Date"].flatMap { formatter.date(from: $0) }
            }.sorted()

            let frequency: Subscription.SubscriptionFrequency
            if dates.count >= 2, let first = dates.first, let last = dates.last {
                let avgGap = last.timeIntervalSince(first) / Double(max(1, dates.count - 1))
                let avgDays = avgGap / 86400
                if avgDays < 2 { frequency = .daily }
                else if avgDays < 10 { frequency = .weekly }
                else if avgDays < 35 { frequency = .monthly }
                else { frequency = .irregular }
            } else {
                frequency = .irregular
            }

            let repliedCount = emails.filter { email in
                emails.contains { other in
                    other.headers["In-Reply-To"]?.contains(email.headers["Message-ID"] ?? "____") ?? false
                }
            }.count
            let engagement = Double(repliedCount) / Double(max(1, emails.count))

            let senderName = extractDisplayName(from: emails.first?.headers["From"] ?? domain, fallback: domain)

            return Subscription(
                id: domain,
                senderDomain: domain,
                senderName: senderName,
                emailCount: emails.count,
                category: category,
                frequency: frequency,
                hasUnsubscribe: hasUnsubscribe,
                lastReceived: dates.last,
                readEngagement: engagement
            )
        }.sorted { $0.emailCount > $1.emailCount }
    }

    // MARK: - Contact Relationship Scoring

    static func scoreContactRelationships(emails: [MBOXParser.RawEmail], userEmail: String? = nil) -> [ContactRelationship] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let tagger = NLTagger(tagSchemes: [.sentimentScore, .lexicalClass])

        var contactData: [String: (name: String, sent: [MBOXParser.RawEmail], received: [MBOXParser.RawEmail], dates: [Date])] = [:]

        for email in emails {
            let fromAddr = extractEmailAddress(from: email.headers["From"] ?? "")
            let fromName = extractDisplayName(from: email.headers["From"] ?? "", fallback: fromAddr)
            let date = email.headers["Date"].flatMap { formatter.date(from: $0) }

            let recipients = extractAllRecipients(from: email)

            if let user = userEmail?.lowercased(), fromAddr == user {
                for recip in recipients {
                    var entry = contactData[recip, default: (recip, [], [], [])]
                    entry.sent.append(email)
                    if let d = date { entry.dates.append(d) }
                    contactData[recip] = entry
                }
            } else {
                var entry = contactData[fromAddr, default: (fromName, [], [], [])]
                entry.received.append(email)
                if let d = date { entry.dates.append(d) }
                contactData[fromAddr] = entry
            }
        }

        return contactData.compactMap { address, data -> ContactRelationship? in
            let totalCount = data.sent.count + data.received.count
            guard totalCount >= 2 else { return nil }

            let reciprocity: Double
            if data.sent.count == 0 || data.received.count == 0 {
                reciprocity = 0.1
            } else {
                reciprocity = Double(min(data.sent.count, data.received.count)) / Double(max(data.sent.count, data.received.count))
            }

            let sortedDates = data.dates.sorted()
            let recency = sortedDates.last

            let recencyScore: Double
            if let last = recency {
                let daysSince = Date().timeIntervalSince(last) / 86400
                recencyScore = max(0, 1.0 - daysSince / 365.0)
            } else {
                recencyScore = 0
            }

            let frequencyScore = min(1.0, Double(totalCount) / 50.0)

            var sentiments: [Double] = []
            for email in (data.sent + data.received).prefix(20) {
                let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
                tagger.string = text
                if let tag = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0,
                   let score = Double(tag.rawValue) {
                    sentiments.append(score)
                }
            }
            let avgSentiment = sentiments.isEmpty ? 0 : sentiments.reduce(0, +) / Double(sentiments.count)

            var topics: [String: Int] = [:]
            for email in (data.sent + data.received).prefix(20) {
                let text = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(500))
                tagger.string = text
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
                    if tag == .noun {
                        let word = String(text[range]).lowercased()
                        if word.count > 3 { topics[word, default: 0] += 1 }
                    }
                    return true
                }
            }
            let topTopics = topics.sorted { $0.value > $1.value }.prefix(5).map { $0.key }

            let importanceScore = (frequencyScore * 0.3 + reciprocity * 0.25 + recencyScore * 0.25 + max(0, avgSentiment + 0.5) * 0.2)

            let relationship: ContactRelationship.RelationshipType
            if reciprocity > 0.4 && frequencyScore > 0.3 && recencyScore > 0.3 {
                relationship = .close
            } else if reciprocity > 0.2 && frequencyScore > 0.15 {
                relationship = .regular
            } else if reciprocity < 0.15 && totalCount >= 3 {
                relationship = .oneWay
            } else if recencyScore < 0.2 && totalCount >= 5 {
                relationship = .dormant
            } else {
                relationship = .acquaintance
            }

            return ContactRelationship(
                id: address,
                name: data.name,
                email: address,
                importanceScore: importanceScore,
                frequency: totalCount,
                reciprocity: reciprocity,
                recency: recency,
                avgSentiment: avgSentiment,
                topTopics: topTopics,
                relationship: relationship
            )
        }.sorted { $0.importanceScore > $1.importanceScore }
    }

    // MARK: - Response Urgency Detection

    static func detectResponseUrgency(emails: [MBOXParser.RawEmail]) -> [ResponseUrgency] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let repliedMessageIDs: Set<String> = Set(emails.compactMap { $0.headers["In-Reply-To"] })

        return emails.compactMap { email -> ResponseUrgency? in
            let messageID = email.headers["Message-ID"] ?? ""
            if repliedMessageIDs.contains(messageID) { return nil }

            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
            let subject = (email.headers["Subject"] ?? "").lowercased()

            var score: Double = 0
            var reasons: [String] = []

            let urgentPhrases = ["urgent", "asap", "immediately", "time-sensitive", "critical"]
            for phrase in urgentPhrases where body.contains(phrase) || subject.contains(phrase) {
                score += 0.3
                reasons.append("Contains urgency indicator: '\(phrase)'")
                break
            }

            let questionCount = body.components(separatedBy: "?").count - 1
            if questionCount >= 2 {
                score += 0.15
                reasons.append("Contains \(questionCount) questions requiring answers")
            } else if questionCount == 1 {
                score += 0.05
                reasons.append("Contains a direct question")
            }

            let requestPhrases = ["please reply", "please respond", "need your", "waiting for your", "your thoughts", "your feedback"]
            for phrase in requestPhrases where body.contains(phrase) {
                score += 0.2
                reasons.append("Explicit response request detected")
                break
            }

            if let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) {
                let age = Date().timeIntervalSince(date) / 86400
                if age < 1 {
                    score += 0.1
                    reasons.append("Received today")
                } else if age < 3 {
                    score += 0.05
                } else if age > 7 {
                    score += 0.15
                    reasons.append("Unanswered for \(Int(age)) days")
                }
            }

            if email.headers["X-Priority"] == "1" || email.headers["Importance"]?.lowercased() == "high" {
                score += 0.2
                reasons.append("Marked as high priority by sender")
            }

            guard score >= 0.15 else { return nil }

            let suggestedTime: String
            switch score {
            case 0.6...: suggestedTime = "Reply within 1 hour"
            case 0.4..<0.6: suggestedTime = "Reply today"
            case 0.25..<0.4: suggestedTime = "Reply within 2-3 days"
            default: suggestedTime = "Reply this week"
            }

            return ResponseUrgency(
                id: email.id,
                email: email,
                urgencyScore: min(1.0, score),
                reasons: reasons,
                suggestedResponseTime: suggestedTime
            )
        }.sorted { $0.urgencyScore > $1.urgencyScore }
    }

    // MARK: - Email Habit Analytics

    static func analyzeEmailHabits(emails: [MBOXParser.RawEmail]) -> [EmailHabitInsight] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let calendar = Calendar.current

        var insights: [EmailHabitInsight] = []
        var hourCounts = [Int](repeating: 0, count: 24)
        var dayCounts = [Int](repeating: 0, count: 7)
        var monthlyVolumes: [String: Int] = [:]
        var dates: [Date] = []

        for email in emails {
            guard let dateStr = email.headers["Date"], let date = formatter.date(from: dateStr) else { continue }
            dates.append(date)

            let hour = calendar.component(.hour, from: date)
            hourCounts[hour] += 1

            let weekday = calendar.component(.weekday, from: date) - 1
            dayCounts[weekday] += 1

            let monthFormatter = DateFormatter()
            monthFormatter.dateFormat = "yyyy-MM"
            monthlyVolumes[monthFormatter.string(from: date), default: 0] += 1
        }

        if let peakHour = hourCounts.enumerated().max(by: { $0.element < $1.element }) {
            let period = peakHour.offset < 12 ? "AM" : "PM"
            let displayHour = peakHour.offset == 0 ? 12 : (peakHour.offset > 12 ? peakHour.offset - 12 : peakHour.offset)
            insights.append(EmailHabitInsight(
                id: "peak_hour",
                title: "Peak Email Hour",
                detail: "Most emails are sent/received at \(displayHour) \(period) (\(peakHour.element) emails)",
                metric: "\(displayHour) \(period)",
                category: .timing
            ))
        }

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if let peakDay = dayCounts.enumerated().max(by: { $0.element < $1.element }) {
            insights.append(EmailHabitInsight(
                id: "peak_day",
                title: "Busiest Day",
                detail: "\(dayNames[peakDay.offset]) is the busiest email day with \(peakDay.element) emails",
                metric: dayNames[peakDay.offset],
                category: .timing
            ))
        }

        let weekendCount = dayCounts[0] + dayCounts[6]
        let weekdayCount = dayCounts[1...5].reduce(0, +)
        if weekendCount > 0 {
            let weekendPct = Double(weekendCount) / Double(max(1, weekendCount + weekdayCount)) * 100
            insights.append(EmailHabitInsight(
                id: "weekend_ratio",
                title: "Weekend Activity",
                detail: "\(Int(weekendPct))% of emails occur on weekends (\(weekendCount) emails)",
                metric: "\(Int(weekendPct))%",
                category: .timing
            ))
        }

        if !monthlyVolumes.isEmpty {
            let sorted = monthlyVolumes.sorted { $0.key > $1.key }
            let recent = sorted.prefix(3)
            let avgRecent = recent.map(\.value).reduce(0, +) / max(1, recent.count)
            let older = sorted.dropFirst(3).prefix(3)
            let avgOlder = older.isEmpty ? avgRecent : older.map(\.value).reduce(0, +) / max(1, older.count)

            if avgOlder > 0 {
                let change = Double(avgRecent - avgOlder) / Double(avgOlder) * 100
                let direction = change > 0 ? "increased" : "decreased"
                insights.append(EmailHabitInsight(
                    id: "volume_trend",
                    title: "Volume Trend",
                    detail: "Email volume has \(direction) by \(abs(Int(change)))% in recent months",
                    metric: "\(change > 0 ? "+" : "")\(Int(change))%",
                    category: .volume
                ))
            }
        }

        let sentCount = emails.filter { ($0.headers["From"] ?? "").contains("@") }.count
        let receivedCount = emails.count - sentCount
        if emails.count > 0 {
            let sentRatio = Double(sentCount) / Double(emails.count) * 100
            insights.append(EmailHabitInsight(
                id: "sent_ratio",
                title: "Send vs Receive",
                detail: "You sent \(Int(sentRatio))% of emails (\(sentCount) sent, \(receivedCount) received)",
                metric: "\(Int(sentRatio))% sent",
                category: .volume
            ))
        }

        let threaded = emails.filter { $0.headers["In-Reply-To"] != nil || $0.inReplyTo != nil }
        if !threaded.isEmpty {
            let threadRate = Double(threaded.count) / Double(emails.count) * 100
            insights.append(EmailHabitInsight(
                id: "thread_rate",
                title: "Conversation Rate",
                detail: "\(Int(threadRate))% of emails are part of ongoing conversations",
                metric: "\(Int(threadRate))%",
                category: .responsiveness
            ))
        }

        return insights
    }

    // MARK: - Helpers

    private static func extractActionSnippet(containing pattern: String, from text: String, contextChars: Int = 80) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: pattern) else { return String(text.prefix(150)) }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let line = String(text[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
        return String(line.prefix(200))
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

    private static func extractDomain(from text: String) -> String? {
        let address = extractEmailAddress(from: text)
        guard let atIndex = address.range(of: "@") else { return nil }
        return String(address[atIndex.upperBound...]).lowercased()
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
