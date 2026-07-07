import Foundation
import NaturalLanguage
import Contacts
import EventKit

struct EmailTagResult {
    let category: String
    let sentiment: String?
    let priority: String?
}

#if canImport(FoundationModels)
import FoundationModels

// MARK: - @Generable Structured Output Types

@available(macOS 26, iOS 26, *)
@Generable(description: "A prioritized email item")
struct EmailTriageItem {
    @Guide(description: "Email subject")
    var subject: String
    @Guide(description: "Sender")
    var sender: String
    @Guide(description: "Why important")
    var reason: String
    @Guide(description: "Recommended action")
    var action: String
    var urgency: EmailTriageUrgency
}

@available(macOS 26, iOS 26, *)
@Generable
enum EmailTriageUrgency: String {
    case actNow
    case today
    case thisWeek
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Email triage results")
struct EmailTriageResult {
    @Guide(description: "Prioritized emails", .maximumCount(10))
    var items: [EmailTriageItem]
    @Guide(description: "Overall assessment")
    var summary: String
}

@available(macOS 26, iOS 26, *)
@Generable(description: "An insight from email analysis")
struct EmailInsightItem {
    @Guide(description: "Short heading")
    var heading: String
    @Guide(description: "Explanation with evidence")
    var detail: String
    var category: EmailInsightCategory
}

@available(macOS 26, iOS 26, *)
@Generable
enum EmailInsightCategory: String {
    case pattern
    case anomaly
    case actionNeeded
    case trend
    case risk
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Email archive insights")
struct EmailInsightsResult {
    @Guide(description: "Insights", .maximumCount(5))
    var insights: [EmailInsightItem]
    @Guide(description: "Health summary")
    var healthSummary: String
}

@available(macOS 26, iOS 26, *)
@Generable(description: "A security finding")
struct EmailSecurityFinding {
    @Guide(description: "Email subject")
    var subject: String
    @Guide(description: "Sender")
    var sender: String
    var riskLevel: SecurityRiskLevel
    @Guide(description: "What is suspicious")
    var explanation: String
    @Guide(description: "Recommended action")
    var remediation: String
}

@available(macOS 26, iOS 26, *)
@Generable
enum SecurityRiskLevel: String {
    case safe
    case caution
    case atRisk
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Security brief")
struct EmailSecurityBrief {
    @Guide(description: "Findings", .maximumCount(10))
    var findings: [EmailSecurityFinding]
    var overallPosture: SecurityRiskLevel
    @Guide(description: "Summary")
    var summary: String
}

// MARK: - AI Intent Classification (Generable)

@available(macOS 26, iOS 26, *)
@Generable
enum AIQueryIntent: String {
    case search
    case statistics
    case sentiment
    case summary
    case security
    case triage
    case thread
    case entity
    case topicAnalysis
    case temporal
    case general
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Classify the user's question about their email archive")
struct AIIntentResult {
    @Guide(description: "The primary intent category")
    var intent: AIQueryIntent
    @Guide(description: "Key search terms or names extracted from the query")
    var extractedTerms: [String]
    @Guide(description: "True if this is a follow-up to a previous question")
    var isFollowUp: Bool
}

// MARK: - Conversational Intent Classification (Apple AI parallel classifier)

@available(macOS 26, iOS 26, *)
@Generable
enum AIConversationalType: String {
    case greeting
    case acknowledgment
    case capability
    case emailQuery
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Classify whether the user is chatting or asking about emails")
struct AIConversationalClassification {
    @Guide(description: "The type of message")
    var messageType: AIConversationalType
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Response to a conversational message")
struct AIConversationalResponse {
    @Guide(description: "true if this is conversational (greeting, chit-chat, about-me, capability question), false if about emails")
    var isConversational: Bool
    @Guide(description: "Natural response if conversational, empty if email query")
    var response: String
}

// MARK: - Query Plan (Apple AI decomposes complex queries)

@available(macOS 26, iOS 26, *)
@Generable(description: "A plan for answering a complex email question")
struct AIQueryPlan {
    @Guide(description: "Is this query complex enough to need multi-step processing?")
    var needsMultiStep: Bool
    @Guide(description: "Sub-queries to execute (each will get its own focused context)", .maximumCount(4))
    var subQueries: [String]
    @Guide(description: "What to focus on when combining sub-results into the final answer")
    var synthesisGoal: String
}

// MARK: - Structured Session Findings (compact intermediate output for multi-session pipeline)

@available(macOS 26, iOS 26, *)
@Generable
enum FindingRelevance: String {
    case high
    case medium
    case low
}

@available(macOS 26, iOS 26, *)
@Generable(description: "A single finding from analyzing emails")
struct AIFinding {
    @Guide(description: "One-sentence finding")
    var finding: String
    @Guide(description: "Email subject or sender that supports this finding")
    var evidence: String
    var relevance: FindingRelevance
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Structured findings from an email analysis session")
struct AISessionFindings {
    @Guide(description: "Key findings, most important first", .maximumCount(5))
    var findings: [AIFinding]
    @Guide(description: "One sentence: what was analyzed and the main takeaway")
    var summary: String
    @Guide(description: "Self-assessed confidence that findings answer the question, 1-5")
    var confidence: Int
}

// MARK: - Merge Layer Output (combining multiple session findings)

@available(macOS 26, iOS 26, *)
@Generable(description: "Merged findings from multiple analysis sessions")
struct AIMergedFindings {
    @Guide(description: "Deduplicated and ranked findings from all sessions", .maximumCount(8))
    var findings: [AIFinding]
    @Guide(description: "Connections or patterns across sessions")
    var crossSessionInsights: String
    @Guide(description: "What key information is still missing or uncertain")
    var gaps: String
}

// MARK: - Per-Email Phishing Classification (Apple AI)

@available(macOS 26, iOS 26, *)
@Generable
enum AIPhishingVerdict: String {
    case safe
    case suspicious
    case phishing
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Phishing classification for one email")
struct AIEmailSafetyResult {
    @Guide(description: "Zero-based index of the email in the batch")
    var index: Int
    var verdict: AIPhishingVerdict
    @Guide(description: "One-sentence reason")
    var reason: String
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Batch phishing classification")
struct AIPhishingBatchResult {
    @Guide(description: "One result per email", .maximumCount(20))
    var results: [AIEmailSafetyResult]
}

// MARK: - AI Email Tagging

@available(macOS 26, iOS 26, *)
@Generable
enum AIEmailCategory: String {
    case personal
    case transactional
    case newsletter
    case promotional
    case automated
    case informational
}

@available(macOS 26, iOS 26, *)
@Generable
enum AISentiment: String {
    case positive
    case negative
    case neutral
}

@available(macOS 26, iOS 26, *)
@Generable
enum AIPriority: String {
    case actionRequired
    case high
    case medium
    case low
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Tags for a single email")
struct AIEmailTags {
    @Guide(description: "Zero-based index of the email in the batch")
    var index: Int
    var category: AIEmailCategory
    var sentiment: AISentiment
    var priority: AIPriority
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Batch email tagging result")
struct AIEmailTagBatchResult {
    @Guide(description: "One result per email", .maximumCount(20))
    var results: [AIEmailTags]
}

// MARK: - AI Entity Enrichment

@available(macOS 26, iOS 26, *)
@Generable
enum AIEntityType: String {
    case person
    case organization
    case place
    case product
    case event
}

@available(macOS 26, iOS 26, *)
@Generable(description: "A refined named entity")
struct AIEntityRefinement {
    @Guide(description: "Zero-based index of the entity in the batch")
    var index: Int
    var entityType: AIEntityType
    @Guide(description: "Corrected or confirmed entity name")
    var correctedName: String
    @Guide(description: "One-word context label, e.g. 'tech company' or 'city'")
    var contextLabel: String
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Batch entity refinement result")
struct AIEntityBatchResult {
    @Guide(description: "One result per entity", .maximumCount(20))
    var results: [AIEntityRefinement]
}

// MARK: - AI Language Detection

@available(macOS 26, iOS 26, *)
@Generable
enum AILanguageCode: String {
    case english
    case spanish
    case french
    case german
    case portuguese
    case italian
    case dutch
    case russian
    case chinese
    case japanese
    case korean
    case arabic
    case hindi
    case turkish
    case polish
    case swedish
    case other
}

@available(macOS 26, iOS 26, *)
@Generable(description: "Language detection for a text snippet")
struct AILanguageResult {
    var language: AILanguageCode
    @Guide(description: "Human-readable language name")
    var languageName: String
}

// MARK: - AI Tools for Dynamic Email Search

@available(macOS 26, iOS 26, *)
struct SearchEmailsTool: Tool {
    let name = "searchEmails"
    let description = "Search the email archive for emails matching keywords"

    @Generable
    struct Arguments {
        @Guide(description: "Search keywords")
        var query: String
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        let terms = EmailNLPEngine.extractSearchTerms(from: arguments.query)
        let results = EmailSearchIndex.shared.hybridSearch(query: arguments.query, terms: terms, limit: 5)
        if results.isEmpty { return "No emails found for '\(arguments.query)'" }
        var output = ""
        for r in results {
            let subj = r.email.headers["Subject"] ?? "(No Subject)"
            let from = r.email.headers["From"] ?? "Unknown"
            let date = r.email.headers["Date"] ?? ""
            let body = FoundationModelEngine.sanitizeForSafetyFilter(String(r.email.plainBody.prefix(300)))
            output += "Subject: \(subj)\nFrom: \(from)\nDate: \(date)\nBody: \(body)\n\n"
        }
        return output
    }
}

@available(macOS 26, iOS 26, *)
struct GetThreadInfoTool: Tool {
    let name = "getThread"
    let description = "Get all emails in a conversation thread by subject keyword"

    @Generable
    struct Arguments {
        @Guide(description: "Subject keyword")
        var subject: String
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        let threads = ThreadGrouper.group(emails)
        let lower = arguments.subject.lowercased()
        guard let thread = threads.first(where: { $0.subject.lowercased().contains(lower) }) else {
            return "No thread found for '\(arguments.subject)'"
        }
        var output = "Thread: \(thread.subject) (\(thread.count) emails)\n\n"
        let sorted = thread.allEmails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }
        for email in sorted.prefix(10) {
            let from = email.headers["From"] ?? "Unknown"
            let date = email.headers["Date"] ?? ""
            output += "From: \(from) (\(date))\n\(FoundationModelEngine.sanitizeForSafetyFilter(String(email.plainBody.prefix(200))))\n\n"
        }
        return output
    }
}

// MARK: - MoE Expert Tools

@available(macOS 26, iOS 26, *)
struct ContactLookupTool: Tool {
    let name = "lookupContact"
    let description = "Look up a person in the user's Contacts by name or email to get their real identity, organization, and phone"

    @Generable
    struct Arguments {
        @Guide(description: "Name or email address to look up")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            let granted = try await store.requestAccess(for: .contacts)
            if !granted { return "Contacts access not granted" }
        } else if status != .authorized {
            return "Contacts access not available"
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        var contacts: [CNContact] = []
        if arguments.query.contains("@") {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: arguments.query)
            contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        }
        if contacts.isEmpty {
            let predicate = CNContact.predicateForContacts(matchingName: arguments.query)
            contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        }

        if contacts.isEmpty { return "No contact found for '\(arguments.query)'" }

        var output = ""
        for contact in contacts.prefix(3) {
            output += "Name: \(contact.givenName) \(contact.familyName)\n"
            if !contact.organizationName.isEmpty { output += "Org: \(contact.organizationName)\n" }
            if !contact.jobTitle.isEmpty { output += "Title: \(contact.jobTitle)\n" }
            for email in contact.emailAddresses { output += "Email: \(email.value as String)\n" }
            for phone in contact.phoneNumbers { output += "Phone: \(phone.value.stringValue)\n" }
            output += "\n"
        }
        return output
    }
}

@available(macOS 26, iOS 26, *)
struct CalendarCheckTool: Tool {
    let name = "checkCalendar"
    let description = "Check the user's calendar for events or meetings with a specific person or topic"

    @Generable
    struct Arguments {
        @Guide(description: "Person name, topic, or keyword to search calendar events")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            if !granted { return "Calendar access not granted" }
        } catch {
            return "Calendar access unavailable"
        }

        let cal = Calendar.current
        guard let start = cal.date(byAdding: .month, value: -1, to: Date()),
              let end = cal.date(byAdding: .month, value: 1, to: Date()) else {
            return "Unable to compute date range"
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let q = arguments.query.lowercased()
        let matching = events.filter { event in
            let title = (event.title ?? "").lowercased()
            let notes = (event.notes ?? "").lowercased()
            let attendees = event.attendees?.compactMap { $0.name?.lowercased() } ?? []
            return title.contains(q) || notes.contains(q) || attendees.contains(where: { $0.contains(q) })
        }

        if matching.isEmpty { return "No calendar events found for '\(arguments.query)'" }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        var output = "Found \(matching.count) event(s):\n\n"
        for event in matching.prefix(5) {
            output += "\(event.title ?? "(No title)")\n"
            output += "  When: \(fmt.string(from: event.startDate)) – \(fmt.string(from: event.endDate))\n"
            if let attendees = event.attendees, !attendees.isEmpty {
                output += "  With: \(attendees.compactMap(\.name).joined(separator: ", "))\n"
            }
            if let loc = event.location, !loc.isEmpty { output += "  Where: \(loc)\n" }
            output += "\n"
        }
        return output
    }
}

@available(macOS 26, iOS 26, *)
struct NLPAnalysisTool: Tool {
    let name = "analyzeEmails"
    let description = "Run on-device NLP analysis: sentiment, entities, topics, classification, or priority scoring"

    @Generable
    struct Arguments {
        var analysisType: NLPAnalysisType
    }

    @Generable
    enum NLPAnalysisType: String {
        case sentiment
        case entities
        case topics
        case classification
        case priority
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        switch arguments.analysisType {
        case .sentiment:
            let r = EmailNLPEngine.averageSentiment(of: emails)
            return "Sentiment: \(r.label) (avg \(String(format: "%.2f", r.average))). Positive: \(r.positive), Neutral: \(r.neutral), Negative: \(r.negative)"
        case .entities:
            let entities = EmailNLPEngine.extractEntities(from: emails, limit: 10)
            if entities.isEmpty { return "No named entities found" }
            return entities.map { "\($0.name) (\($0.type), \($0.count)x)" }.joined(separator: "\n")
        case .topics:
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 10)
            if topics.isEmpty { return "No clear topics found" }
            return topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: "\n")
        case .classification:
            let cls = EmailNLPEngine.classifyAll(emails)
            return EmailNLPEngine.EmailCategory.allCases.compactMap { c -> String? in
                guard let n = cls[c], n > 0 else { return nil }; return "\(c.rawValue): \(n)"
            }.joined(separator: "\n")
        case .priority:
            let rc: [String: Int] = Dictionary(
                emails.compactMap { $0.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) }.map { ($0, 1) },
                uniquingKeysWith: +
            )
            let p = EmailNLPEngine.scoreAllPriorities(emails, replyCountPerSender: rc)
            return p.prefix(5).map { "\($0.email.headers["Subject"] ?? "(No Subject)") — \($0.level.rawValue) (score: \($0.score))" }.joined(separator: "\n")
        }
    }
}

// MARK: - Spotlight Intelligence Tool (Apple AI generated summaries + semantic search)

@available(macOS 26, iOS 26, *)
struct SpotlightSearchTool: Tool {
    let name = "spotlightSearch"
    let description = "Apple Intelligence semantic search — finds emails by meaning, not just keywords. Also returns AI-generated summaries if available."

    @Generable
    struct Arguments {
        @Guide(description: "Natural language search query")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let results = await SpotlightIndexer.shared.semanticSearch(query: arguments.query, limit: 5)
        if results.isEmpty { return "No emails found for '\(arguments.query)'" }

        var output = "Spotlight found \(results.count) email(s):\n\n"
        for r in results {
            output += "Subject: \(r.title)\n"
            if !r.snippet.isEmpty { output += "AI Summary: \(r.snippet)\n" }
            if let uuid = UUID(uuidString: r.id), await SpotlightIndexer.shared.isAIPriority(uuid) {
                output += "Priority: Apple Intelligence flagged as HIGH PRIORITY\n"
            }
            output += "\n"
        }
        return output
    }
}

// MARK: - Phishing Intelligence Tool (local NLP + enrichment for Apple AI)

@available(macOS 26, iOS 26, *)
struct PhishingAnalysisTool: Tool {
    let name = "analyzePhishing"
    let description = "Run on-device phishing detection on emails — checks for scam patterns, suspicious senders, and PII exposure"

    @Generable
    struct Arguments {
        @Guide(description: "Optional sender name or keyword to focus analysis on, or 'all' for full scan")
        var focus: String
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        let target: [MBOXParser.RawEmail]
        if arguments.focus.lowercased() == "all" || arguments.focus.isEmpty {
            target = emails
        } else {
            let q = arguments.focus.lowercased()
            target = emails.filter { email in
                let from = (email.headers["From"] ?? "").lowercased()
                let subj = (email.headers["Subject"] ?? "").lowercased()
                return from.contains(q) || subj.contains(q)
            }
        }

        if target.isEmpty { return "No emails found matching '\(arguments.focus)'" }

        let flags = EmailNLPEngine.detectPhishing(in: target)
        let pii = EmailNLPEngine.piiSummary(in: target)

        var output = "Scanned \(target.count) emails:\n"
        if flags.isEmpty {
            output += "No phishing indicators detected.\n"
        } else {
            output += "\(flags.count) suspicious email(s):\n\n"
            for flag in flags.prefix(5) {
                output += "Subject: \(flag.email.headers["Subject"] ?? "(No Subject)")\n"
                output += "From: \(flag.email.headers["From"] ?? "Unknown")\n"
                output += "Risk: \(flag.riskLevel.rawValue)\n"
                output += "Reasons: \(flag.reasons.joined(separator: "; "))\n\n"
            }
        }
        if !pii.isEmpty {
            output += "PII detected: " + pii.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ")
        }
        return output
    }
}

// MARK: - Sender Profile Tool (drill into any sender's emails)

@available(macOS 26, iOS 26, *)
struct SenderProfileTool: Tool {
    let name = "getSenderProfile"
    let description = "Get a detailed profile of a specific sender: email count, topics, sentiment, recent subjects, and timeline"

    @Generable
    struct Arguments {
        @Guide(description: "Sender name or email address to profile")
        var sender: String
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        let q = arguments.sender.lowercased()
        let senderEmails = emails.filter {
            ($0.headers["From"] ?? "").lowercased().contains(q)
        }
        if senderEmails.isEmpty { return "No emails found from '\(arguments.sender)'" }

        let sentiment = EmailNLPEngine.averageSentiment(of: senderEmails)
        let topics = EmailNLPEngine.extractTopics(from: senderEmails, limit: 5)
        let dates = senderEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let f = DateFormatter(); f.dateStyle = .medium

        var output = "Profile for \(arguments.sender):\n"
        output += "Emails: \(senderEmails.count)\n"
        output += "Sentiment: \(sentiment.label) (avg \(String(format: "%.2f", sentiment.average)))\n"
        if let first = dates.first, let last = dates.last {
            output += "Active: \(f.string(from: first)) to \(f.string(from: last))\n"
        }
        if !topics.isEmpty {
            output += "Topics: " + topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: ", ") + "\n"
        }
        output += "Recent subjects:\n"
        let recent = senderEmails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) >
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }
        for email in recent.prefix(5) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let date = email.headers["Date"] ?? ""
            output += "  • \(subj) (\(date))\n"
        }
        return output
    }
}

// MARK: - Topic Drill Tool (deep-dive into any topic)

@available(macOS 26, iOS 26, *)
struct TopicDrillTool: Tool {
    let name = "drillIntoTopic"
    let description = "Get all emails related to a specific topic or keyword with sender breakdown and sentiment"

    @Generable
    struct Arguments {
        @Guide(description: "Topic keyword to investigate")
        var topic: String
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        let q = arguments.topic.lowercased()
        let matching = emails.filter {
            ($0.headers["Subject"] ?? "").lowercased().contains(q) ||
            $0.plainBody.lowercased().contains(q)
        }
        if matching.isEmpty { return "No emails about '\(arguments.topic)'" }

        let sentiment = EmailNLPEngine.averageSentiment(of: matching)
        var senderCounts: [String: Int] = [:]
        for email in matching {
            let from = email.headers["From"] ?? "Unknown"
            senderCounts[from, default: 0] += 1
        }
        let topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(5)

        var output = "Topic '\(arguments.topic)': \(matching.count) emails\n"
        output += "Sentiment: \(sentiment.label)\n"
        output += "Discussed by: " + topSenders.map { "\($0.key) (\($0.value))" }.joined(separator: ", ") + "\n"
        output += "Key emails:\n"
        for email in matching.prefix(5) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let body = FoundationModelEngine.sanitizeForSafetyFilter(String(email.plainBody.prefix(150)))
            output += "  • \(subj) from \(from): \(body)\n"
        }
        return output
    }
}

// MARK: - Attachment Analysis Tool (v4.1.1)

@available(macOS 26, iOS 26, *)
struct AttachmentAnalysisTool: Tool {
    let name = "analyzeAttachments"
    let description = "Search and analyze attachment content (PDFs, images via OCR, documents) across the email archive"

    @Generable
    struct Arguments {
        @Guide(description: "Search query for attachment content, or email subject/sender to get specific attachment details")
        var query: String
    }

    let emails: [MBOXParser.RawEmail]

    func call(arguments: Arguments) async throws -> String {
        let terms = EmailNLPEngine.extractSearchTerms(from: arguments.query)

        // Search attachment content
        let attachResults = EmailSearchIndex.shared.searchAttachmentContent(terms: terms.isEmpty ? [arguments.query] : terms, limit: 5)
        if !attachResults.isEmpty {
            var output = "ATTACHMENT CONTENT MATCHES (\(attachResults.count)):\n"
            for r in attachResults {
                let subj = r.email.headers["Subject"] ?? "(No Subject)"
                let from = r.email.headers["From"] ?? "Unknown"
                let attachList = r.email.attachments.map(\.filename).joined(separator: ", ")
                output += "Email: \(subj) from \(from)\n"
                output += "Attachments: \(attachList)\n"
                let text = EmailSearchIndex.shared.getAttachmentText(for: r.email.id) ?? ""
                output += "Content: \(String(text.prefix(300)))\n\n"
            }
            return output
        }

        // Fallback: find emails with attachments matching the query
        let qLower = arguments.query.lowercased()
        let withAttachments = emails.filter { email in
            !email.attachments.isEmpty && (
                email.attachments.contains(where: { $0.filename.lowercased().contains(qLower) }) ||
                (email.headers["Subject"] ?? "").lowercased().contains(qLower) ||
                (email.headers["From"] ?? "").lowercased().contains(qLower)
            )
        }

        if !withAttachments.isEmpty {
            var output = "EMAILS WITH ATTACHMENTS (\(withAttachments.count)):\n"
            for email in withAttachments.prefix(5) {
                output += EmailSearchIndex.shared.getAttachmentSummary(for: email) + "\n"
            }
            return output
        }

        // Last resort: show attachment statistics
        let totalWithAttachments = emails.filter { !$0.attachments.isEmpty }.count
        let allAttachments = emails.flatMap(\.attachments)
        let types = Dictionary(grouping: allAttachments, by: \.mimeType).mapValues(\.count).sorted { $0.value > $1.value }
        var output = "No specific matches for '\(arguments.query)'. Archive attachment overview:\n"
        output += "\(totalWithAttachments) emails with attachments (\(allAttachments.count) total files)\n"
        output += "Types: " + types.prefix(5).map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "\n"
        return output
    }
}

@available(macOS 26, iOS 26, *)
struct VisualizationRecommendTool: Tool {
    let name = "recommendVisualization"
    let description = "Recommend the best visualization type for a user query about their email data: topicFlow, communicationHeatmap, sentimentTimeline, or relationshipMap"

    @Generable
    struct Arguments {
        @Guide(description: "The user's visualization or analysis query")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let vizType = AIVisualizationGenerator.recommendVisualization(for: arguments.query)
        return "RECOMMENDED: \(vizType.rawValue) — \(vizType.title). This visualization best answers queries about \(vizDescription(vizType))."
    }

    private func vizDescription(_ type: VisualizationType) -> String {
        switch type {
        case .topicFlow: return "how discussion topics change over time periods"
        case .communicationHeatmap: return "when email activity peaks by day of week and hour"
        case .sentimentTimeline: return "how communication tone and mood trends evolve"
        case .relationshipMap: return "contact networks, key connectors, and relationship patterns"
        }
    }
}

// MARK: - Knowledge Graph Query Tool (v3.1.3)

@available(macOS 26, iOS 26, *)
struct KnowledgeGraphQueryTool: Tool {
    let name = "queryKnowledgeGraph"
    let description = "Query the email knowledge graph to find relationships between people, organizations, topics, and domains. Use this to answer questions about who communicates with whom, what topics connect people, and how entities are related."

    @Generable
    struct Arguments {
        @Guide(description: "The entity name, email address, topic, or domain to look up in the knowledge graph")
        var query: String
        @Guide(description: "Type of query: 'relationships' to find connections, 'path' to find how two entities connect (use 'entity1 -> entity2' format), 'overview' for graph statistics")
        var queryType: String?
    }

    func call(arguments: Arguments) async throws -> String {
        guard let graph = FoundationModelEngine.getKnowledgeGraph(), graph.nodeCount > 0 else {
            return "Knowledge graph not available. Import emails first to build the graph."
        }

        let qt = arguments.queryType?.lowercased() ?? "relationships"

        if qt == "overview" {
            return graph.summaryForAI(focus: arguments.query, limit: 15)
        }

        if qt == "path", arguments.query.contains("->") {
            let parts = arguments.query.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let nodesA = graph.findNodes(matching: parts[0])
                let nodesB = graph.findNodes(matching: parts[1])
                if let a = nodesA.first, let b = nodesB.first {
                    if let path = graph.shortestPath(from: a.id, to: b.id) {
                        let labels = path.compactMap { graph.findNode(id: $0)?.label }
                        let strength = graph.connectionStrength(between: a.id, nodeB: b.id)
                        return "PATH: \(labels.joined(separator: " → "))\nConnection strength: \(String(format: "%.0f", strength))\nHops: \(path.count - 1)"
                    }
                    return "No path found between '\(parts[0])' and '\(parts[1])'"
                }
                return "Could not find nodes matching '\(parts[0])' or '\(parts[1])'"
            }
        }

        let matches = graph.findNodes(matching: arguments.query)
        if matches.isEmpty {
            return "No entities found matching '\(arguments.query)' in the knowledge graph."
        }

        var output = ""
        for node in matches.prefix(3) {
            output += "\(node.type.rawValue.uppercased()): \(node.label) (weight: \(String(format: "%.0f", node.weight)))\n"

            let neighborsByType: [KGEdgeType: [KGNode]] = {
                var grouped: [KGEdgeType: [KGNode]] = [:]
                for edge in graph.edgesFrom(node.id) + graph.edgesTo(node.id) {
                    let neighborID = edge.sourceID == node.id ? edge.targetID : edge.sourceID
                    if let n = graph.findNode(id: neighborID) {
                        grouped[edge.type, default: []].append(n)
                    }
                }
                return grouped
            }()

            for (edgeType, neighbors) in neighborsByType.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let sorted = neighbors.sorted { $0.weight > $1.weight }
                let labels = sorted.prefix(5).map { "\($0.label) (\($0.type.rawValue))" }
                output += "  \(edgeType.rawValue): \(labels.joined(separator: ", "))\n"
            }
            output += "\n"
        }

        return output
    }
}

// MARK: - Foundation Model Engine

@available(macOS 26, iOS 26, *)
struct FoundationModelEngine {

    enum ModelAvailability {
        case available
        case notEligible
        case notEnabled
        case notReady
        case unknown
    }

    static var availability: ModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .notReady
        default:
            return .unknown
        }
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // v4.3.1: Current persona for AI behavior
    @MainActor
    static var personaForCurrentSession: PersonaManager.Persona {
        PersonaManager.shared.selectedPersona
    }

    private static func prepareSession(query: String, emails: [MBOXParser.RawEmail]) -> (session: LanguageModelSession, prompt: String) {
        let searchTerms = EmailNLPEngine.extractSearchTerms(from: query)
        let contextEmails: [MBOXParser.RawEmail]

        let indexResults = EmailSearchIndex.shared.hybridSearch(query: query, terms: searchTerms, limit: 15)
        if indexResults.count >= 3 {
            contextEmails = indexResults.map(\.email)
        } else if !searchTerms.isEmpty {
            let results = EmailNLPEngine.searchEmails(terms: searchTerms, in: emails, limit: 15)
            contextEmails = results.count >= 3 ? results.map(\.email) : Array(emails.prefix(20))
        } else {
            contextEmails = Array(emails.prefix(20))
        }

        let emailContext = buildContext(from: contextEmails, allEmails: emails)

        let instructions = """
            You are an email analyst in mailin (on-device, private). \
            First identify what the user is asking, then answer with evidence from the emails. \
            Refer to emails by **Subject** and **sender** in bold. Use bullet points. \
            If emails shown don't cover the question, use searchEmails tool.
            """

        let session = LanguageModelSession(
            tools: [SearchEmailsTool(emails: emails), GetThreadInfoTool(emails: emails)],
            instructions: instructions
        )

        let isRAG = contextEmails.count < emails.count
        let prompt = """
            Email archive: \(emails.count) total emails\(isRAG ? " (\(contextEmails.count) most relevant shown below)" : ""):

            \(emailContext)

            User question: \(query)
            """

        return (session, prompt)
    }

    static func respond(to query: String, emails: [MBOXParser.RawEmail]) async throws -> String {
        guard isAvailable else { return "Apple AI is not available on this device." }
        let prepared = prepareSession(query: query, emails: emails)
        let response = try await prepared.session.respond(to: prepared.prompt)
        return response.content
    }

    static func respondStreaming(to query: String, emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard isAvailable else {
            let msg = "Apple AI is not available on this device."
            await onUpdate(msg)
            return msg
        }
        let prepared = prepareSession(query: query, emails: emails)
        let stream = prepared.session.streamResponse(to: prepared.prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - Hybrid: NLP retrieval + Apple AI synthesis

    static func synthesizeFromNLPResults(
        query: String,
        retrievedEmails: [MBOXParser.RawEmail],
        nlpAnalysis: String,
        allEmailCount: Int,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        var context = "RETRIEVED BY NLP ENGINE (\(retrievedEmails.count) of \(allEmailCount) total emails):\n\n"

        // Include NLP structured analysis as grounding data
        if !nlpAnalysis.isEmpty {
            context += "NLP ANALYSIS (verified on-device data — trust these numbers):\n\(nlpAnalysis)\n\n"
        }

        context += "RELEVANT EMAILS:\n\n"
        let emailBudget = max(0, contextCharBudget - context.count - 200)
        var emailChars = 0
        for email in retrievedEmails.prefix(15) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let snippetLen = emailChars < emailBudget / 2 ? 400 : 200
            let body = bodySnippet(for: email, maxLength: snippetLen)
            let entry = """
                --- \(subj) ---
                From: \(email.headers["From"] ?? "Unknown")
                Date: \(email.headers["Date"] ?? "")
                Body: \(body)

                """
            if emailChars + entry.count > emailBudget { break }
            context += entry
            emailChars += entry.count
        }

        let personaConfig = await PersonaManager.aiConfig(for: personaForCurrentSession)
        let instructions = """
            \(personaConfig.systemInstruction) \
            You work in mailin, a privacy-first Mac app. \
            The NLP engine has already retrieved the most relevant emails and computed \
            verified statistics. Your job is to synthesize these into a natural, \
            insightful answer.

            Rules:
            - The NLP analysis numbers (counts, sentiment scores, classifications) are \
              computed deterministically — use them as ground truth
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never as \
              "Email 1" or "Email 2". For example say "**Q1 Product Launch Strategy** from \
              **Sarah Johnson**" not "Email 1"
            - Quote specific email content to support your points
            - Use **bold** for names, dates, and key terms
            - Connect dots across emails — identify patterns and insights
            - Keep responses focused and evidence-based
            - Use the searchEmails tool if you need more context beyond the provided emails
            - Synthesis guidance: \(personaConfig.synthesisGuidance)
            """

        let session = LanguageModelSession(
            tools: [SearchEmailsTool(emails: retrievedEmails)],
            instructions: instructions
        )
        let prompt = "User question: \(query)\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - Agentic RAG Synthesis

    static func synthesizeFromAgenticRAG(
        query: String,
        retrievedEmails: [MBOXParser.RawEmail],
        keyChunks: [(subject: String, from: String, chunk: String)],
        threadTimeline: String,
        nlpAnalysis: String,
        retrievalSteps: [String],
        allEmailCount: Int,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        guard !retrievedEmails.isEmpty else {
            let msg = "I couldn't find emails relevant to your query. Try rephrasing or using different keywords."
            await onUpdate(msg)
            return msg
        }
        var context = "AGENTIC RETRIEVAL (\(retrievedEmails.count) of \(allEmailCount) total emails):\n\n"

        context += "RETRIEVAL PIPELINE:\n"
        for step in retrievalSteps { context += "- \(step)\n" }
        context += "\n"

        if !nlpAnalysis.isEmpty {
            context += "NLP ANALYSIS (verified on-device — trust these numbers):\n\(nlpAnalysis)\n\n"
        }

        if !threadTimeline.isEmpty {
            context += "\(threadTimeline)\n"
        }

        if !keyChunks.isEmpty {
            context += "KEY PASSAGES (most relevant excerpts extracted by chunk search):\n\n"
            for (i, chunk) in keyChunks.enumerated() {
                context += "[\(i + 1)] From \(chunk.from), Re: \(chunk.subject):\n\"\(chunk.chunk)\"\n\n"
            }
        }

        let convMemory = conversationContext()
        if !convMemory.isEmpty {
            context += "\(convMemory)\n"
        }

        context += "EMAILS:\n\n"
        let emailBudget = max(0, contextCharBudget - context.count - 200)
        var emailChars = 0
        for email in retrievedEmails.prefix(15) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let snippetLen = emailChars < emailBudget / 2 ? 400 : 200
            let body = queryFocusedSnippet(for: email, query: query, maxLength: snippetLen)
            let entry = """
                --- \(subj) ---
                From: \(sanitizeForSafetyFilter(email.headers["From"] ?? "Unknown"))
                Date: \(email.headers["Date"] ?? "")
                Body: \(body)

                """
            if emailChars + entry.count > emailBudget { break }
            context += entry
            emailChars += entry.count
        }

        let personaConfig = await PersonaManager.aiConfig(for: personaForCurrentSession)
        let instructions = """
            \(personaConfig.systemInstruction) \
            You work in mailin, a privacy-first Mac app. \
            An agentic retrieval pipeline has already: searched with BM25 + semantic vectors, \
            expanded conversation threads for full context, extracted the most relevant \
            passages via chunk-level scoring, and computed verified NLP statistics.

            Rules:
            - The NLP analysis numbers (counts, sentiment, classifications) are deterministic \
              ground truth — use them as-is, never guess different numbers
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never as \
              "Email 1" or "Email 2". For example say "**Q1 Product Launch Strategy** from \
              **Sarah Johnson**" not "Email 1"
            - Quote the KEY PASSAGES directly — they are the most relevant excerpts
            - Use the CONVERSATION THREADS timeline to narrate how discussions evolved over time
            - Connect dots across emails — identify patterns, outcomes, turning points, and insights
            - Use **bold** for names, dates, and key terms
            - Structure complex answers with bullet points or numbered lists
            - Keep responses focused and evidence-based — every claim should trace to an email
            - Use the searchEmails tool if you need more context beyond the provided emails
            - Synthesis guidance: \(personaConfig.synthesisGuidance)
            """

        let session = LanguageModelSession(
            tools: [SearchEmailsTool(emails: retrievedEmails)],
            instructions: instructions
        )
        let prompt = "User question: \(query)\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - Hybrid Expert Synthesis (best hybrid: NLP + RAG + MoE experts + fan-in)

    struct HybridExpertResult {
        let answer: String
        let intent: QueryIntent
        let totalFindings: Int
        let highRelevanceCount: Int
        let layerCount: Int
    }

    static func hybridExpertSynthesis(
        query: String,
        emails: [MBOXParser.RawEmail],
        ragRetrievedEmails: [MBOXParser.RawEmail],
        ragKeyChunks: [(subject: String, from: String, chunk: String)],
        ragTimeline: String,
        ragAnalysis: String,
        ragSteps: [String],
        nlpBaseline: String,
        allEmailCount: Int,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> HybridExpertResult {
        let intent = await classifyIntent(query)
        let sessionConfig = computeSessionCount(query: query, emails: emails, intent: intent)
        let profile = archiveProfile(emails: emails)

        let allExperts = selectExperts(for: intent)
        let experts = Array(allExperts.prefix(sessionConfig.experts))

        // Query decomposition: NLP first (free), AI fallback
        let nlpSubQueries = decomposeQueryNLP(query, emails: emails)
        var subQueries: [String] = []
        if nlpSubQueries.count >= 2 {
            subQueries = Array(nlpSubQueries.prefix(sessionConfig.maxSubQueries))
        } else if emails.count >= multiSessionThreshold {
            if let plan = await planQuery(query: query, profile: profile), plan.needsMultiStep {
                subQueries = Array(plan.subQueries.prefix(sessionConfig.maxSubQueries))
            }
        }

        let totalParallel = experts.count + subQueries.count
        await onUpdate("*Hybrid Layer 1: NLP baseline ready — deploying \(totalParallel) parallel expert sessions...*\n\n")

        // Layer 1: Run on-device experts + sub-queries + cloud experts in parallel
        var expertFindings: [(ExpertRole, AISessionFindings)] = []
        var subFindings: [(String, AISessionFindings)] = []

        #if !OFFLINE_MODE
        var cloudExpertResults: [CloudExpertFinding] = []
        let cloudAIReady = await CloudAIManager.shared.isReady
        let cloudRoles: [CloudAIManager.CloudExpertRole] = cloudAIReady
            ? [.worldKnowledge, .security]
            : []
        let emailCtxForCloud = cloudAIReady
            ? CloudAIManager.buildEmailContext(from: ragRetrievedEmails.isEmpty ? emails : ragRetrievedEmails, maxEmails: 10)
            : ""
        let totalWithCloud = totalParallel + cloudRoles.count

        await withTaskGroup(of: (String, Int?, ExpertRole?, AISessionFindings?, CloudExpertFinding?).self) { group in
            for expert in experts {
                group.addTask {
                    let findings = await runExpertStructured(role: expert, query: query, emails: ragRetrievedEmails.isEmpty ? emails : ragRetrievedEmails)
                    return ("expert", nil, expert, findings, nil)
                }
            }
            for (i, subQ) in subQueries.enumerated() {
                let capturedSubQ = subQ
                group.addTask {
                    let findings = await executeSubQueryStructured(subQuery: capturedSubQ, emails: emails, profile: profile)
                    return ("map", i, nil, findings, nil)
                }
            }
            for role in cloudRoles {
                let nlpSnippet = String(nlpBaseline.prefix(600))
                let ctx = emailCtxForCloud
                group.addTask {
                    let result = try? await CloudAIManager.shared.runExpert(
                        role: role,
                        query: query,
                        emailContext: ctx,
                        nlpData: nlpSnippet
                    )
                    return ("cloud", nil, nil, nil, result)
                }
            }

            var mapIndexed: [(Int, String, AISessionFindings)] = []
            for await (type, idx, role, findings, cloudResult) in group {
                if type == "expert", let r = role, let f = findings {
                    expertFindings.append((r, f))
                } else if type == "map", let i = idx, i < subQueries.count, let f = findings {
                    mapIndexed.append((i, subQueries[i], f))
                } else if type == "cloud", let cr = cloudResult {
                    cloudExpertResults.append(cr)
                }
            }
            subFindings = mapIndexed.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
        #else
        let cloudAIReady = false
        let totalWithCloud = totalParallel

        await withTaskGroup(of: (String, Int?, ExpertRole?, AISessionFindings?).self) { group in
            for expert in experts {
                group.addTask {
                    let findings = await runExpertStructured(role: expert, query: query, emails: ragRetrievedEmails.isEmpty ? emails : ragRetrievedEmails)
                    return ("expert", nil, expert, findings)
                }
            }
            for (i, subQ) in subQueries.enumerated() {
                let capturedSubQ = subQ
                group.addTask {
                    let findings = await executeSubQueryStructured(subQuery: capturedSubQ, emails: emails, profile: profile)
                    return ("map", i, nil, findings)
                }
            }

            var mapIndexed: [(Int, String, AISessionFindings)] = []
            for await (type, idx, role, findings) in group {
                if type == "expert", let r = role, let f = findings {
                    expertFindings.append((r, f))
                } else if type == "map", let i = idx, i < subQueries.count, let f = findings {
                    mapIndexed.append((i, subQueries[i], f))
                }
            }
            subFindings = mapIndexed.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
        #endif

        // Collect and track evidence
        var allFindings: [(source: String, finding: AIFinding, confidence: Int)] = []
        var trackedFindings: [TrackedFinding] = []

        for (role, sessionF) in expertFindings {
            for finding in sessionF.findings {
                allFindings.append((source: role.rawValue, finding: finding, confidence: sessionF.confidence))
                trackedFindings.append(trackEvidence(finding: finding, source: role.rawValue, confidence: sessionF.confidence, emails: ragRetrievedEmails.isEmpty ? emails : ragRetrievedEmails))
            }
        }
        for (subQ, sessionF) in subFindings {
            for finding in sessionF.findings {
                allFindings.append((source: subQ, finding: finding, confidence: sessionF.confidence))
                trackedFindings.append(trackEvidence(finding: finding, source: subQ, confidence: sessionF.confidence, emails: emails))
            }
        }

        #if !OFFLINE_MODE
        // Integrate cloud expert findings into the unified findings list
        for cloudResult in cloudExpertResults {
            for f in cloudResult.findings {
                let relevance: FindingRelevance = f.relevance == "HIGH" ? .high : f.relevance == "MEDIUM" ? .medium : .low
                let aiFinding = AIFinding(finding: f.finding, evidence: f.evidence, relevance: relevance)
                allFindings.append((source: "Cloud: \(cloudResult.role.rawValue)", finding: aiFinding, confidence: cloudResult.confidence))
            }
        }
        #endif

        let linkedCount = trackedFindings.filter { !$0.emailIDs.isEmpty }.count

        allFindings.sort { a, b in
            let aScore = (a.finding.relevance == .high ? 3 : a.finding.relevance == .medium ? 2 : 1) + a.confidence
            let bScore = (b.finding.relevance == .high ? 3 : b.finding.relevance == .medium ? 2 : 1) + b.confidence
            return aScore > bScore
        }

        // Dynamic intent-aware fan-in
        let findingsText = serializeFindings(allFindings)
        let hybridBudget = contextBudget(for: intent)
        let profileBudget = min(profile.count, hybridBudget.profileChars)
        let availableBudget = hybridBudget.findingsChars + hybridBudget.emailBodyChars

        var finalFindingsText: String
        var layerCount: Int

        if findingsText.count <= availableBudget {
            finalFindingsText = findingsText
            layerCount = 2
        } else {
            let highFindings = allFindings.filter { $0.finding.relevance == .high }
            let secondaryFindings = allFindings.filter { $0.finding.relevance != .high }
            let highText = serializeFindings(highFindings)

            await onUpdate("*Hybrid Layer 2: Merging \(secondaryFindings.count) secondary findings...*\n\n")
            let mergedText = !secondaryFindings.isEmpty ? await mergeFindings(findings: secondaryFindings, query: query) : ""

            finalFindingsText = highText + "\n\n" + mergedText
            if finalFindingsText.count <= availableBudget {
                layerCount = 3
            } else {
                finalFindingsText = String(finalFindingsText.prefix(availableBudget))
                layerCount = 4
            }
        }

        let highCount = allFindings.filter { $0.finding.relevance == .high }.count
        await onUpdate("*Hybrid Layer \(layerCount): Synthesizing \(allFindings.count) findings (\(highCount) high-relevance, \(linkedCount) linked to emails)...*\n\n")

        // Build synthesis context: RAG evidence + expert findings + NLP baseline
        var synthesisContext = String(profile.prefix(profileBudget)) + "\n\n"

        synthesisContext += "NLP BASELINE ANSWER (deterministic, verified on-device):\n\(String(nlpBaseline.prefix(600)))\n\n"

        if !ragAnalysis.isEmpty {
            synthesisContext += "RAG ANALYSIS:\n\(ragAnalysis)\n\n"
        }
        if !ragTimeline.isEmpty {
            synthesisContext += "\(String(ragTimeline.prefix(800)))\n\n"
        }
        if !ragKeyChunks.isEmpty {
            synthesisContext += "KEY PASSAGES:\n"
            for (i, chunk) in ragKeyChunks.prefix(8).enumerated() {
                synthesisContext += "[\(i+1)] From \(chunk.from), Re: \(chunk.subject):\n\"\(chunk.chunk)\"\n\n"
            }
        }

        synthesisContext += "\n" + finalFindingsText + "\n\n"

        // v4.3.3: Inject plugin findings into synthesis context
        let pluginText = await PluginManager.shared.allFindingsForAI()
        if !pluginText.isEmpty {
            synthesisContext += "PLUGIN FINDINGS:\n\(String(pluginText.prefix(600)))\n\n"
        }

        let convoCtx = conversationContext()
        if !convoCtx.isEmpty {
            synthesisContext = String(convoCtx.prefix(400)) + "\n" + synthesisContext
        }

        synthesisContext += "EMAILS:\n\n"
        let targetEmails = ragRetrievedEmails.isEmpty ? Array(emails.prefix(15)) : ragRetrievedEmails
        let emailBudget = max(0, contextCharBudget - synthesisContext.count - 200)
        var emailChars = 0
        for email in targetEmails.prefix(15) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let snippetLen = emailChars < emailBudget / 2 ? 400 : 200
            let body = queryFocusedSnippet(for: email, query: query, maxLength: snippetLen)
            let entry = "--- \(subj) ---\nFrom: \(sanitizeForSafetyFilter(email.headers["From"] ?? "Unknown"))\nDate: \(email.headers["Date"] ?? "")\nBody: \(body)\n\n"
            if emailChars + entry.count > emailBudget { break }
            synthesisContext += entry
            emailChars += entry.count
        }

        synthesisContext = String(synthesisContext.prefix(contextCharBudget))

        #if !OFFLINE_MODE
        // Append cloud expert findings to synthesis context
        if !cloudExpertResults.isEmpty {
            synthesisContext += "\nCLOUD EXPERT FINDINGS (world knowledge + advanced analysis):\n"
            for cr in cloudExpertResults {
                synthesisContext += cr.asFormattedText() + "\n"
            }
        }
        let cloudExpertCount = cloudExpertResults.count
        #else
        let cloudExpertCount = 0
        #endif
        let personaConfig = await PersonaManager.aiConfig(for: personaForCurrentSession)
        let instructions = """
            \(personaConfig.systemInstruction) \
            Synthesize \(allFindings.count) findings (\(highCount) high-relevance) \
            from \(experts.count) experts into one answer. NLP baseline numbers are ground truth. \
            ▲=high ●=medium ▽=low relevance. Cite emails by **Subject** and **sender**. \
            Answer the user's exact question first, then add insights. Use bullet points. \
            \(personaConfig.synthesisGuidance)
            """

        let tools = selectTools(for: intent, emails: targetEmails)
        let session = tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)

        let prompt = "\(synthesisContext)\n\nAnswer this question: \(query)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }

        // Cloud cross-validation when available and findings are substantial
        #if !OFFLINE_MODE
        if cloudAIReady && allFindings.count >= 3 {
            let validationEmailCtx = CloudAIManager.buildEmailContext(
                from: ragRetrievedEmails.isEmpty ? emails : ragRetrievedEmails, maxEmails: 8
            )
            if let validation = try? await CloudAIManager.shared.crossValidate(
                answer: finalContent, query: query, emailContext: validationEmailCtx
            ) {
                if !validation.isAccurate && validation.confidence >= 3 {
                    let missing = validation.missing
                    let issues = validation.issues
                    if missing != "none" && !missing.isEmpty {
                        finalContent += "\n\n---\n**Additional context** (cloud-verified): \(missing)"
                    }
                    if issues != "none" && !issues.isEmpty {
                        finalContent += "\n\n> ⚠️ Note: \(issues)"
                    }
                }
            }
        }
        #endif

        recordTurn(query: query, intent: intent, answer: finalContent)

        return HybridExpertResult(
            answer: finalContent,
            intent: intent,
            totalFindings: allFindings.count,
            highRelevanceCount: highCount,
            layerCount: layerCount + (cloudExpertCount > 0 ? 1 : 0)
        )
    }

    static func summarize(emails: [MBOXParser.RawEmail]) async throws -> String {
        guard isAvailable else { return "Apple AI is not available on this device." }
        let emailContext = buildContext(from: emails)

        let instructions = """
            You are an email archive analyst. Provide a concise, insightful summary \
            of the email archive. Include: overall themes, key contacts, sentiment, \
            notable patterns, and any interesting observations. Be specific with names \
            and topics. Keep the summary to 3-5 short paragraphs.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Summarize this email archive:\n\n\(emailContext)")
        return response.content
    }

    // MARK: - Targeted Expert Analysis (public API for views)

    enum AnalysisScope: Sendable {
        case sentiment
        case entity
        case topic
        case timeline
        case security
        case digest
        case investigation
        case all
    }

    static func enhanceWithAI(
        scope: AnalysisScope,
        emails: [MBOXParser.RawEmail],
        context: String = ""
    ) async -> String? {
        guard isAvailable, !emails.isEmpty else { return nil }

        let roles: [ExpertRole]
        switch scope {
        case .sentiment: roles = [.sentimentExpert]
        case .entity: roles = [.entityExpert]
        case .topic: roles = [.topicExpert]
        case .timeline: roles = [.timelineExpert]
        case .security: roles = [.securityExpert]
        case .digest: roles = [.sentimentExpert, .topicExpert, .timelineExpert, .entityExpert]
        case .investigation: roles = ExpertRole.allCases
        case .all: roles = ExpertRole.allCases
        }

        let query = context.isEmpty ? "Analyze this email collection" : context

        let findings = await withTaskGroup(of: (ExpertRole, AISessionFindings).self) { group in
            for role in roles {
                group.addTask {
                    let result = await runExpertStructured(role: role, query: query, emails: emails)
                    return (role, result)
                }
            }
            var results: [(ExpertRole, AISessionFindings)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        var output = ""
        for (role, sessionF) in findings {
            let highFindings = sessionF.findings.filter { $0.relevance == .high }
            let medFindings = sessionF.findings.filter { $0.relevance == .medium }
            let relevant = highFindings + medFindings

            if !relevant.isEmpty {
                let label: String
                switch role {
                case .sentimentExpert: label = "Sentiment"
                case .entityExpert: label = "People & Relationships"
                case .topicExpert: label = "Topics & Content"
                case .timelineExpert: label = "Timeline Patterns"
                case .securityExpert: label = "Security"
                }
                output += "**\(label):**\n"
                for finding in relevant {
                    let icon = finding.relevance == .high ? "▲" : "●"
                    output += "\(icon) \(finding.finding)"
                    if !finding.evidence.isEmpty { output += " — \(finding.evidence)" }
                    output += "\n"
                }
                output += "\n"
            }
        }

        return output.isEmpty ? nil : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Smart Triage / Priority Inbox

    static func triageEmails(_ emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !emails.isEmpty else {
            let msg = "No emails to triage. Import emails first."
            await onUpdate(msg)
            return msg
        }
        guard isAvailable else {
            let msg = "Apple AI is not available on this device."
            await onUpdate(msg)
            return msg
        }
        let replyCountPerSender: [String: Int] = Dictionary(
            emails.compactMap { $0.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        let priorityResults = EmailNLPEngine.scoreAllPriorities(emails, replyCountPerSender: replyCountPerSender)
        let topEmails = Array(priorityResults.prefix(10))

        var context = "PRIORITY TRIAGE — Top \(topEmails.count) high-priority emails from \(emails.count) total:\n\n"
        for (_, result) in topEmails.enumerated() {
            let email = result.email
            let subj = email.headers["Subject"] ?? "(No Subject)"
            context += """
                --- \(subj) (score: \(result.score), level: \(result.level.rawValue)) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(subj)
                Date: \(email.headers["Date"] ?? "")
                Priority reasons: \(result.reasons.joined(separator: ", "))
                Body: \(bodySnippet(for: email, maxLength: 400))

                """
        }

        let instructions = """
            You are an email triage specialist in mailin, a privacy-first Mac app. \
            The NLP engine has scored and ranked emails by priority. Your job is to \
            explain why each email matters and suggest specific actions.

            Rules:
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never as \
              "Email 1" or "Message 2"
            - For each email, explain WHY it's important in one sentence
            - Suggest a specific action (reply, delegate, schedule, archive)
            - Group by urgency: "Act Now", "Today", "This Week"
            - Use **bold** for names, deadlines, and key terms
            - Be concise and actionable — like a personal assistant briefing
            """

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Triage these priority emails and recommend actions:\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - Proactive Insights Dashboard

    static func generateInsights(_ emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !emails.isEmpty else {
            let msg = "No emails to analyze. Import emails first."
            await onUpdate(msg)
            return msg
        }
        guard isAvailable else {
            let msg = "Apple AI is not available on this device."
            await onUpdate(msg)
            return msg
        }
        let classification = EmailNLPEngine.classifyAll(emails)
        let sentiment = EmailNLPEngine.averageSentiment(of: emails)
        let entities = EmailNLPEngine.extractEntities(from: emails, limit: 10)
        let contacts = EmailNLPEngine.contactInsights(from: emails, limit: 8)
        let topics = EmailNLPEngine.extractTopics(from: emails, limit: 8)

        // Recent activity patterns
        let now = Date()
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let recentEmails = emails.filter { email in
            guard let dateStr = email.headers["Date"],
                  let date = MBOXParser.parseDate(dateStr) else { return false }
            return date > oneWeekAgo
        }
        let unansweredReceived = recentEmails.filter { $0.messageType == "received" }

        var context = "INSIGHTS DATA for \(emails.count) emails:\n\n"

        // Category distribution
        let catStrings = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> String? in
            guard let count = classification[cat], count > 0 else { return nil }
            return "\(cat.rawValue): \(count)"
        }
        context += "Categories: \(catStrings.joined(separator: ", "))\n"

        // Sentiment summary
        context += "Sentiment: \(sentiment.label) (avg \(String(format: "%.2f", sentiment.average))). "
        context += "Positive: \(sentiment.positive), Neutral: \(sentiment.neutral), Negative: \(sentiment.negative)\n"

        // Top entities
        if !entities.isEmpty {
            context += "Top entities: \(entities.map { "\($0.name) (\($0.type), \($0.count)x)" }.joined(separator: ", "))\n"
        }

        // Contact sentiment insights
        if !contacts.isEmpty {
            context += "Contact insights:\n"
            for contact in contacts {
                context += "  - \(contact.address): \(contact.emailCount) emails, sentiment: \(contact.sentimentLabel)\n"
            }
        }

        // Topics
        if !topics.isEmpty {
            context += "Key topics: \(topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: ", "))\n"
        }

        // Recent activity
        context += "\nRecent activity (last 7 days): \(recentEmails.count) emails, \(unansweredReceived.count) received\n"

        let instructions = """
            You are a proactive email intelligence analyst in mailin, a privacy-first Mac app. \
            The NLP engine has computed verified statistics about the user's email archive. \
            Generate 3-5 actionable insights the user might not have noticed.

            Rules:
            - Each insight should be specific and data-backed (cite numbers from NLP analysis)
            - Examples: unanswered emails, sentiment shifts with contacts, category imbalances, \
              neglected threads, unusual patterns
            - Use **bold** for names, numbers, and key findings
            - Be conversational — like a smart assistant noticing patterns
            - Start each insight with a short descriptive heading
            - Prioritize actionable findings over obvious observations
            """

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Generate proactive insights from this email analysis:\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - Thread Narrative Synthesis

    static func synthesizeThread(_ emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !emails.isEmpty else {
            let msg = "No emails in this thread."
            await onUpdate(msg)
            return msg
        }
        guard isAvailable else {
            let msg = "Apple AI is not available on this device."
            await onUpdate(msg)
            return msg
        }

        // Sort emails by date
        let sorted = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }

        var context = "CONVERSATION THREAD — \(sorted.count) emails:\n\n"
        for (_, email) in sorted.enumerated() {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            context += """
                --- \(subj) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(subj)
                Date: \(email.headers["Date"] ?? "")
                Body: \(bodySnippet(for: email, maxLength: 600))

                """
        }

        let instructions = """
            You are an email conversation narrator in mailin, a privacy-first Mac app. \
            Create a narrative timeline of the conversation thread.

            Rules:
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never as \
              "Email 1" or "Message 2"
            - Narrate the conversation chronologically like a story
            - Highlight key decisions, turning points, and action items
            - Note tone shifts and sentiment changes between messages
            - Use **bold** for participant names, dates, and key decisions
            - Call out any unresolved questions or pending action items at the end
            - Be concise — focus on what matters, skip pleasantries
            - Use a timeline format with dates as anchors
            """

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Create a narrative timeline for this email thread:\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - Security Brief

    static func securityBrief(_ emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !emails.isEmpty else {
            let msg = "No emails to analyze for security. Import emails first."
            await onUpdate(msg)
            return msg
        }
        guard isAvailable else {
            let msg = "Apple AI is not available on this device."
            await onUpdate(msg)
            return msg
        }
        let phishingFlags = EmailNLPEngine.detectPhishing(in: emails)
        let piiSummary = EmailNLPEngine.piiSummary(in: emails)

        var context = "EMAIL SAFETY REVIEW of \(emails.count) messages:\n\n"

        if phishingFlags.isEmpty {
            context += "Trust scan: All messages appear normal.\n\n"
        } else {
            context += "FLAGGED MESSAGES (\(phishingFlags.count) need review):\n"
            for (i, flag) in phishingFlags.prefix(10).enumerated() {
                context += """
                    [\(i + 1)] Risk: \(flag.riskLevel.rawValue)
                    From: \(sanitizeForSafetyFilter(flag.email.headers["From"] ?? "Unknown"))
                    Subject: \(sanitizeForSafetyFilter(flag.email.headers["Subject"] ?? "(No Subject)"))
                    Reasons: \(flag.reasons.joined(separator: "; "))

                    """
            }
            if phishingFlags.count > 10 {
                context += "... and \(phishingFlags.count - 10) more flagged emails\n"
            }
            context += "\n"
        }

        // PII findings
        if piiSummary.isEmpty {
            context += "PII scan: No personally identifiable information detected.\n"
        } else {
            context += "PII DETECTED:\n"
            for (type, count) in piiSummary {
                context += "  - \(type.rawValue): \(count) instance(s)\n"
            }
        }

        let instructions = """
            You are a helpful email safety advisor in mailin, a privacy-first Mac app. \
            The app has automatically scanned the user's email archive to help them \
            understand which emails need caution. Summarize the findings for the user.

            Rules:
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never by number
            - Explain each finding in plain, non-technical language
            - For flagged emails: explain why caution is warranted
            - For personal data exposure: explain what was found and suggest next steps
            - Provide specific, actionable recommendations for each finding
            - Use **bold** for importance levels, sender names, and action items
            - Rate overall inbox safety: Safe / Caution Advised / Needs Attention
            - Be helpful and proportionate — explain without alarming
            """

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Summarize this email safety review for the user:\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    // MARK: - AI Draft Reply Suggestions

    enum ReplyTone: String, CaseIterable {
        case professional = "Professional"
        case friendly = "Friendly"
        case brief = "Brief"
        case formal = "Formal"
    }

    static func suggestReply(to email: MBOXParser.RawEmail, tone: ReplyTone = .professional, onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard isAvailable else {
            let msg = "Apple AI is not available on this device."
            await onUpdate(msg)
            return msg
        }
        let from = email.headers["From"] ?? "Unknown"
        let subject = email.headers["Subject"] ?? "(No Subject)"
        let body = bodySnippet(for: email, maxLength: 1500)
        let date = email.headers["Date"] ?? ""

        let instructions = """
            You are an expert email reply assistant in mailin, a privacy-first Mac app. \
            All processing is 100% on-device. Draft a concise, well-written reply email.

            Rules:
            - Write ONLY the reply body text (no headers, no "Subject:", no "To:")
            - Match the requested tone exactly
            - Be concise — most replies should be 2-6 sentences
            - Reference specific points from the original email when relevant
            - Include a brief greeting and sign-off appropriate to the tone
            - Do not invent facts — only reference what's in the original email
            - If the original email asks questions, answer them helpfully
            - For "Brief" tone: keep it to 1-3 sentences maximum
            """

        let session = LanguageModelSession(instructions: instructions)

        let prompt = """
            Draft a \(tone.rawValue.lowercased()) reply to this email:

            From: \(from)
            Subject: \(subject)
            Date: \(date)
            Body: \(body)

            Write a \(tone.rawValue.lowercased()) reply:
            """

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }
        return finalContent
    }

    static func analyzeSentiment(emails: [MBOXParser.RawEmail]) async throws -> String {
        guard isAvailable else { return "Apple AI is not available on this device." }
        let emailContext = buildContext(from: emails)

        let instructions = """
            You are an email sentiment analyst. Analyze the emotional tone of the \
            provided emails. Categorize the overall sentiment and identify the most \
            positive and negative emails. Be specific about what makes them positive \
            or negative. Keep the response concise.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "Analyze the sentiment of these emails:\n\n\(emailContext)")
        return response.content
    }

    private static func buildContext(from contextEmails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail]? = nil) -> String {
        let statsEmails = allEmails ?? contextEmails
        var context = ""

        let sentCount = statsEmails.filter { $0.messageType == "sent" }.count
        let recvCount = statsEmails.filter { $0.messageType == "received" }.count
        let sentiment = EmailNLPEngine.averageSentiment(of: statsEmails)
        let topics = EmailNLPEngine.extractTopics(from: statsEmails, limit: 8)
        let classification = EmailNLPEngine.classifyAll(statsEmails)
        let dates = statsEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let totalSizeKB = statsEmails.reduce(0) { $0 + $1.rawSource.utf8.count } / 1024

        context += "ARCHIVE STATS:\n"
        context += "Total: \(statsEmails.count) emails (sent: \(sentCount), received: \(recvCount)), \(totalSizeKB) KB\n"
        if let first = dates.first, let last = dates.last {
            let f = DateFormatter()
            f.dateStyle = .medium
            context += "Period: \(f.string(from: first)) to \(f.string(from: last))\n"
        }
        context += "Sentiment: \(sentiment.label) (\(String(format: "%.2f", sentiment.average))). "
        context += "Positive: \(sentiment.positive), Neutral: \(sentiment.neutral), Negative: \(sentiment.negative)\n"
        if !topics.isEmpty {
            context += "Key topics: \(topics.map(\.word).joined(separator: ", "))\n"
        }
        let catStrings = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> String? in
            guard let count = classification[cat], count > 0 else { return nil }
            return "\(cat.rawValue): \(count)"
        }
        if !catStrings.isEmpty {
            context += "Categories: \(catStrings.joined(separator: ", "))\n"
        }

        // Thread grouping summary
        let threads = ThreadGrouper.group(contextEmails)
        let multiEmailThreads = threads.filter { $0.count > 1 }
        if !multiEmailThreads.isEmpty {
            context += "Threads: \(threads.count) conversations (\(multiEmailThreads.count) with multiple emails)\n"
            let topThreads = multiEmailThreads.prefix(5)
            for thread in topThreads {
                context += "  - \"\(thread.subject)\" (\(thread.count) emails)\n"
            }
        }
        context += "\n"

        if let all = allEmails, contextEmails.count < all.count {
            context += "SHOWING \(contextEmails.count) MOST RELEVANT EMAILS (retrieved via semantic search from \(all.count) total):\n\n"
        }

        let snippetLength = allEmails != nil ? 400 : 300
        let sample = Array(contextEmails.prefix(20))
        for (_, email) in sample.enumerated() {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let body = bodySnippet(for: email, maxLength: snippetLength)
            context += """
                --- \(subj) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(subj)
                Date: \(email.headers["Date"] ?? "")
                Type: \(email.messageType)
                Body: \(body)

                """
        }

        if contextEmails.count > 50 {
            context += "\n[... and \(contextEmails.count - 50) more emails not shown]\n"
        }

        return context
    }

    private static func bodySnippet(for email: MBOXParser.RawEmail, maxLength: Int) -> String {
        guard maxLength > 0 else { return "(empty)" }
        let text: String
        if !email.plainBody.isEmpty {
            text = email.plainBody.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
        } else if !email.htmlBody.isEmpty {
            text = email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "(empty)"
        }
        let truncated = text.count <= maxLength ? text : String(text.prefix(maxLength)) + "..."
        return sanitizeForSafetyFilter(truncated)
    }

    private static func queryFocusedSnippet(for email: MBOXParser.RawEmail, query: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "(empty)" }
        let rawText: String
        if !email.plainBody.isEmpty {
            rawText = email.plainBody.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
        } else if !email.htmlBody.isEmpty {
            rawText = email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "(empty)"
        }
        if rawText.count <= maxLength { return rawText }

        let queryTerms = EmailNLPEngine.extractSearchTerms(from: query.lowercased())
        guard !queryTerms.isEmpty else { return String(rawText.prefix(maxLength)) + "..." }

        let sentences = rawText.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 10 }
        guard !sentences.isEmpty else { return String(rawText.prefix(maxLength)) + "..." }

        let scored = sentences.map { sentence -> (String, Int) in
            let lower = sentence.lowercased()
            let hits = queryTerms.filter { lower.contains($0) }.count
            return (sentence, hits)
        }.sorted { $0.1 > $1.1 }

        var result = ""
        for (sentence, _) in scored {
            if result.count + sentence.count + 2 > maxLength { break }
            if !result.isEmpty { result += ". " }
            result += sentence
        }
        let output = result.isEmpty ? String(rawText.prefix(maxLength)) + "..." : result
        return sanitizeForSafetyFilter(output)
    }

    static func sanitizeForSafetyFilter(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: "https?://[^\\s)>\"']+",
            with: "[link]",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "www\\.[^\\s)>\"']+",
            with: "[link]",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            with: "[email]",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Structured Generation (returns typed data instead of free text)

    static func triageStructured(_ emails: [MBOXParser.RawEmail]) async throws -> EmailTriageResult {
        guard !emails.isEmpty else {
            return EmailTriageResult(items: [], summary: "No emails to triage.")
        }
        guard isAvailable else {
            return EmailTriageResult(items: [], summary: "Apple AI is not available on this device.")
        }
        let replyCountPerSender: [String: Int] = Dictionary(
            emails.compactMap { $0.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        let priorityResults = EmailNLPEngine.scoreAllPriorities(emails, replyCountPerSender: replyCountPerSender)
        let topEmails = Array(priorityResults.prefix(10))

        var context = "Priority-scored emails from \(emails.count) total:\n\n"
        for result in topEmails {
            let email = result.email
            let subj = email.headers["Subject"] ?? "(No Subject)"
            context += """
                Subject: \(subj)
                From: \(email.headers["From"] ?? "Unknown")
                Date: \(email.headers["Date"] ?? "")
                Score: \(result.score), Level: \(result.level.rawValue)
                Reasons: \(result.reasons.joined(separator: ", "))
                Body: \(bodySnippet(for: email, maxLength: 300))

                """
        }

        let instructions = """
            You are an email triage specialist. Analyze priority-scored emails and \
            produce structured triage results. Be concise and actionable.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Triage these emails:\n\n\(context)",
            generating: EmailTriageResult.self
        )
        return response.content
    }

    static func insightsStructured(_ emails: [MBOXParser.RawEmail]) async throws -> EmailInsightsResult {
        guard !emails.isEmpty else {
            return EmailInsightsResult(insights: [], healthSummary: "No emails to analyze.")
        }
        guard isAvailable else {
            return EmailInsightsResult(insights: [], healthSummary: "Apple AI is not available on this device.")
        }
        let classification = EmailNLPEngine.classifyAll(emails)
        let sentiment = EmailNLPEngine.averageSentiment(of: emails)
        let contacts = EmailNLPEngine.contactInsights(from: emails, limit: 8)
        let topics = EmailNLPEngine.extractTopics(from: emails, limit: 8)

        var context = "Archive stats for \(emails.count) emails:\n"
        context += "Sentiment: \(sentiment.label) (avg \(String(format: "%.2f", sentiment.average)))\n"
        context += "Positive: \(sentiment.positive), Neutral: \(sentiment.neutral), Negative: \(sentiment.negative)\n"

        let catStrings = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> String? in
            guard let count = classification[cat], count > 0 else { return nil }
            return "\(cat.rawValue): \(count)"
        }
        if !catStrings.isEmpty { context += "Categories: \(catStrings.joined(separator: ", "))\n" }
        if !topics.isEmpty { context += "Topics: \(topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: ", "))\n" }
        if !contacts.isEmpty {
            context += "Top contacts:\n"
            for c in contacts { context += "  \(c.address): \(c.emailCount) emails, sentiment: \(c.sentimentLabel)\n" }
        }

        let instructions = """
            You are an email intelligence analyst. Produce structured insights \
            from verified NLP statistics. Each insight must be specific and data-backed.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Generate insights:\n\n\(context)",
            generating: EmailInsightsResult.self
        )
        return response.content
    }

    static func securityStructured(_ emails: [MBOXParser.RawEmail]) async throws -> EmailSecurityBrief {
        guard !emails.isEmpty else {
            return EmailSecurityBrief(findings: [], overallPosture: .safe, summary: "No emails to analyze.")
        }
        guard isAvailable else {
            return EmailSecurityBrief(findings: [], overallPosture: .safe, summary: "Apple AI is not available on this device.")
        }
        let phishingFlags = EmailNLPEngine.detectPhishing(in: emails)
        let piiSummary = EmailNLPEngine.piiSummary(in: emails)

        var context = "Safety review of \(emails.count) messages:\n\n"
        if phishingFlags.isEmpty {
            context += "Trust scan: All messages appear normal.\n"
        } else {
            context += "Flagged messages (\(phishingFlags.count)):\n"
            for flag in phishingFlags.prefix(10) {
                context += "  Title: \(sanitizeForSafetyFilter(flag.email.headers["Subject"] ?? "(No Subject)"))\n"
                context += "  Sender: \(sanitizeForSafetyFilter(flag.email.headers["From"] ?? "Unknown"))\n"
                context += "  Level: \(flag.riskLevel.rawValue), Notes: \(flag.reasons.joined(separator: "; "))\n\n"
            }
        }
        if !piiSummary.isEmpty {
            context += "PII detected:\n"
            for (type, count) in piiSummary { context += "  \(type.rawValue): \(count)\n" }
        }

        let instructions = "You are an email safety advisor. Produce structured findings about message trustworthiness."

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Security brief:\n\n\(context)",
            generating: EmailSecurityBrief.self
        )
        return response.content
    }

    static func formatTriageResult(_ result: EmailTriageResult) -> String {
        var output = ""
        let groups: [(String, [EmailTriageItem])] = [
            ("Act Now", result.items.filter { $0.urgency == .actNow }),
            ("Today", result.items.filter { $0.urgency == .today }),
            ("This Week", result.items.filter { $0.urgency == .thisWeek })
        ]
        for (label, items) in groups where !items.isEmpty {
            output += "### \(label)\n\n"
            for item in items {
                output += "**\(item.subject)** from **\(item.sender)**\n"
                output += "- \(item.reason)\n"
                output += "- Action: \(item.action)\n\n"
            }
        }
        output += "---\n\(result.summary)"
        return output
    }

    static func formatInsightsResult(_ result: EmailInsightsResult) -> String {
        var output = ""
        for insight in result.insights {
            let icon: String
            switch insight.category {
            case .pattern: icon = "🔄"
            case .anomaly: icon = "⚠️"
            case .actionNeeded: icon = "📌"
            case .trend: icon = "📈"
            case .risk: icon = "🛡️"
            }
            output += "### \(icon) \(insight.heading)\n\n\(insight.detail)\n\n"
        }
        output += "---\n\(result.healthSummary)"
        return output
    }

    // MARK: - Apple AI Phishing Detection (batch)

    // MARK: - Dynamic Parallelism & Batch Sizing (context-aware, 50k+ ready)

    struct AIWorkloadProfile {
        let weight: Weight
        let batchSize: Int
        let parallelism: Int
        let maxAICalls: Int

        enum Weight { case light, medium, heavy }
    }

    private static func profileWorkload(emailCount: Int, emails: [MBOXParser.RawEmail]) -> AIWorkloadProfile {
        // Sample emails to measure content density
        let sampleSize = min(emails.count, 30)
        let sample = emails.prefix(sampleSize)
        var totalChars = 0
        var attachmentCount = 0

        for email in sample {
            let bodyLen = email.plainBody.isEmpty ? email.htmlBody.count : email.plainBody.count
            totalChars += bodyLen + (email.headers["Subject"] ?? "").count
            attachmentCount += email.attachments.count
        }

        let avgChars = sampleSize > 0 ? totalChars / sampleSize : 0
        let avgAttachments = sampleSize > 0 ? Double(attachmentCount) / Double(sampleSize) : 0

        let weight: AIWorkloadProfile.Weight
        if avgChars > 2000 || avgAttachments > 2 { weight = .heavy }
        else if avgChars < 500 && avgAttachments < 1 { weight = .light }
        else { weight = .medium }

        // Batch size scales with volume — larger batches = fewer API calls
        let batchSize: Int
        switch emailCount {
        case 0...100: batchSize = 10
        case 101...500: batchSize = 15
        case 501...2000: batchSize = 20
        case 2001...10000: batchSize = 25
        case 10001...50000: batchSize = 30
        default: batchSize = 40
        }

        let batchCount = max((emailCount + batchSize - 1) / batchSize, 1)

        // Parallelism scales with batch count and weight
        let baseParallelism: Int
        switch batchCount {
        case 0...1: baseParallelism = 1
        case 2...4: baseParallelism = 2
        case 5...10: baseParallelism = 3
        case 11...30: baseParallelism = 5
        case 31...80: baseParallelism = 7
        case 81...200: baseParallelism = 8
        default: baseParallelism = 10
        }

        let parallelism: Int
        switch weight {
        case .light: parallelism = min(baseParallelism + 2, 10)
        case .medium: parallelism = baseParallelism
        case .heavy: parallelism = max(baseParallelism - 1, 1)
        }

        // Cap total AI calls for supplementary features (entities, language)
        // to prevent unbounded processing on huge archives
        let maxAICalls: Int
        switch emailCount {
        case 0...500: maxAICalls = emailCount
        case 501...5000: maxAICalls = 500
        case 5001...20000: maxAICalls = 1000
        default: maxAICalls = 2000
        }

        return AIWorkloadProfile(
            weight: weight,
            batchSize: batchSize,
            parallelism: parallelism,
            maxAICalls: maxAICalls
        )
    }

    private static let phishingInstructions = """
        You are an email inbox organizer helping a user sort their mail. \
        For each message, classify it into one of three categories based on \
        the sender name, title, and preview text. Links and addresses are placeholders. \
        Categories: safe (normal mail), suspicious (unusual or mismatched patterns), \
        or phishing (clearly deceptive). Most messages are safe.
        """

    static func classifyPhishing(
        _ emails: [MBOXParser.RawEmail],
        onProgress: @MainActor @Sendable @escaping (Int, Int) -> Void
    ) async -> Set<UUID> {
        guard isAvailable else { return [] }
        let total = emails.count
        let profile = profileWorkload(emailCount: total, emails: emails)

        var allBatches: [[MBOXParser.RawEmail]] = []
        for startIndex in stride(from: 0, to: total, by: profile.batchSize) {
            let endIndex = min(startIndex + profile.batchSize, total)
            allBatches.append(Array(emails[startIndex..<endIndex]))
        }

        var phishingIDs = Set<UUID>()

        if allBatches.count == 1 {
            let result = await classifyPhishingSingleBatch(allBatches[0])
            phishingIDs.formUnion(result)
            await onProgress(total, total)
            return phishingIDs
        }

        for groupStart in stride(from: 0, to: allBatches.count, by: profile.parallelism) {
            let groupEnd = min(groupStart + profile.parallelism, allBatches.count)
            let group = Array(allBatches[groupStart..<groupEnd])

            let groupResults = await withTaskGroup(of: Set<UUID>.self) { taskGroup in
                for batch in group {
                    taskGroup.addTask {
                        await classifyPhishingSingleBatch(batch)
                    }
                }
                var merged = Set<UUID>()
                for await batchResult in taskGroup {
                    merged.formUnion(batchResult)
                }
                return merged
            }

            phishingIDs.formUnion(groupResults)
            let processed = min(groupEnd * profile.batchSize, total)
            await onProgress(processed, total)
        }

        return phishingIDs
    }

    private static func classifyPhishingSingleBatch(_ batch: [MBOXParser.RawEmail]) async -> Set<UUID> {
        var prompt = "Categorize each message below:\n\n"
        for (i, email) in batch.enumerated() {
            let subj = sanitizeForSafetyFilter(email.headers["Subject"] ?? "(No Subject)")
            let from = sanitizeForSafetyFilter(email.headers["From"] ?? "Unknown")
            let body = bodySnippet(for: email, maxLength: 200)
            prompt += "[\(i)] Sender: \(from)\nTitle: \(subj)\nPreview: \(body)\n\n"
        }

        do {
            let session = LanguageModelSession(instructions: phishingInstructions)
            let response = try await session.respond(to: prompt, generating: AIPhishingBatchResult.self)
            var ids = Set<UUID>()
            for result in response.content.results {
                guard result.index >= 0, result.index < batch.count else { continue }
                if result.verdict == .phishing {
                    ids.insert(batch[result.index].id)
                }
            }
            return ids
        } catch {
            // Batch failed — retry individual emails with capped parallelism
            let retryProfile = profileWorkload(emailCount: batch.count, emails: batch)
            let retryConcurrency = max(retryProfile.parallelism, 2)
            var ids = Set<UUID>()
            for groupStart in stride(from: 0, to: batch.count, by: retryConcurrency) {
                let groupEnd = min(groupStart + retryConcurrency, batch.count)
                let slice = batch[groupStart..<groupEnd]
                let groupIDs = await withTaskGroup(of: UUID?.self) { group in
                    for email in slice {
                        group.addTask {
                            let singlePrompt = "Categorize this message:\nSender: \(sanitizeForSafetyFilter(email.headers["From"] ?? "Unknown"))\nTitle: \(sanitizeForSafetyFilter(email.headers["Subject"] ?? "(No Subject)"))\n"
                            do {
                                let s = LanguageModelSession(instructions: phishingInstructions)
                                let r = try await s.respond(to: singlePrompt, generating: AIEmailSafetyResult.self)
                                return r.content.verdict == .phishing ? email.id : nil
                            } catch {
                                return nil
                            }
                        }
                    }
                    var result = Set<UUID>()
                    for await id in group {
                        if let id { result.insert(id) }
                    }
                    return result
                }
                ids.formUnion(groupIDs)
            }
            return ids
        }
    }

    // MARK: - AI Email Tagging

    private static let tagInstructions = """
        You are an email inbox organizer. For each message, assign a category \
        (personal, transactional, newsletter, promotional, automated, informational), \
        a sentiment (positive, negative, neutral), and a priority level \
        (actionRequired, high, medium, low). Most messages are medium priority and neutral sentiment.
        """

    static func tagEmails(
        _ emails: [MBOXParser.RawEmail],
        onProgress: @MainActor @Sendable @escaping (Int, Int) -> Void
    ) async -> [UUID: EmailTagResult] {
        guard isAvailable else { return [:] }
        let total = emails.count
        let profile = profileWorkload(emailCount: total, emails: emails)

        // Split into batches
        var batches: [(index: Int, emails: [MBOXParser.RawEmail])] = []
        for startIndex in stride(from: 0, to: total, by: profile.batchSize) {
            let endIndex = min(startIndex + profile.batchSize, total)
            batches.append((index: startIndex, emails: Array(emails[startIndex..<endIndex])))
        }

        guard !batches.isEmpty else { return [:] }

        // Single batch — no parallelism needed, no RAG seed needed
        if batches.count == 1 {
            let result = await tagSingleBatch(batches[0].emails, ragExamples: [])
            await onProgress(total, total)
            return result
        }

        // Phase 1: Run first batch sequentially to seed RAG examples
        var results: [UUID: EmailTagResult] = [:]
        var ragExamples: [(subject: String, from: String, category: String)] = []
        let firstBatch = batches[0].emails

        let seedResult = await tagSingleBatch(firstBatch, ragExamples: [])
        for (id, tag) in seedResult {
            results[id] = tag
            if let email = firstBatch.first(where: { $0.id == id }) {
                ragExamples.append((
                    subject: sanitizeForSafetyFilter(email.headers["Subject"] ?? ""),
                    from: sanitizeForSafetyFilter(email.headers["From"] ?? ""),
                    category: tag.category
                ))
            }
        }
        await onProgress(min(profile.batchSize, total), total)

        // Phase 2: Process remaining batches — parallelism scales with workload
        let remainingBatches = Array(batches.dropFirst())
        let ragContext = Array(ragExamples.suffix(3))

        // 2 remaining batches — sequential is fine, skip TaskGroup
        if remainingBatches.count == 1 {
            let batchResult = await tagSingleBatch(remainingBatches[0].emails, ragExamples: ragContext)
            for (id, tag) in batchResult { results[id] = tag }
            await onProgress(total, total)
            return results
        }

        for groupStart in stride(from: 0, to: remainingBatches.count, by: profile.parallelism) {
            let groupEnd = min(groupStart + profile.parallelism, remainingBatches.count)
            let group = Array(remainingBatches[groupStart..<groupEnd])

            let groupResults = await withTaskGroup(of: [UUID: EmailTagResult].self) { taskGroup in
                for batch in group {
                    taskGroup.addTask {
                        await tagSingleBatch(batch.emails, ragExamples: ragContext)
                    }
                }
                var merged: [UUID: EmailTagResult] = [:]
                for await batchResult in taskGroup {
                    for (id, tag) in batchResult {
                        merged[id] = tag
                    }
                }
                return merged
            }

            for (id, tag) in groupResults {
                results[id] = tag
            }

            let processed = min((1 + groupEnd) * profile.batchSize, total)
            await onProgress(processed, total)
        }

        return results
    }

    private static func tagSingleBatch(
        _ batch: [MBOXParser.RawEmail],
        ragExamples: [(subject: String, from: String, category: String)]
    ) async -> [UUID: EmailTagResult] {
        var prompt = ""
        if !ragExamples.isEmpty {
            prompt += "Examples of prior classifications:\n"
            for ex in ragExamples {
                prompt += "  Sender: \(ex.from), Title: \(ex.subject) → \(ex.category)\n"
            }
            prompt += "\nNow classify each message:\n\n"
        } else {
            prompt += "Classify each message:\n\n"
        }

        for (i, email) in batch.enumerated() {
            let subj = sanitizeForSafetyFilter(email.headers["Subject"] ?? "(No Subject)")
            let from = sanitizeForSafetyFilter(email.headers["From"] ?? "Unknown")
            let body = bodySnippet(for: email, maxLength: 150)
            prompt += "[\(i)] Sender: \(from)\nTitle: \(subj)\nPreview: \(body)\n\n"
        }

        do {
            let session = LanguageModelSession(instructions: tagInstructions)
            let response = try await session.respond(to: prompt, generating: AIEmailTagBatchResult.self)
            var results: [UUID: EmailTagResult] = [:]
            for tag in response.content.results {
                guard tag.index >= 0, tag.index < batch.count else { continue }
                let cat = tag.category.rawValue.capitalized
                results[batch[tag.index].id] = EmailTagResult(
                    category: cat,
                    sentiment: tag.sentiment == .neutral ? nil : tag.sentiment.rawValue.capitalized,
                    priority: tag.priority == .medium || tag.priority == .low ? nil : (tag.priority == .actionRequired ? "Action Required" : "High Priority")
                )
            }
            return results
        } catch {
            return [:]
        }
    }

    // MARK: - Entity Enrichment (NLP extracts → Apple AI refines)

    struct EntityInput {
        let name: String
        let type: String
    }

    struct EnrichedEntity {
        let name: String
        let type: String
        let contextLabel: String
    }

    static func enrichEntities(_ entities: [EntityInput]) async -> [EnrichedEntity] {
        guard isAvailable, !entities.isEmpty else {
            return entities.map { EnrichedEntity(name: $0.name, type: $0.type, contextLabel: "") }
        }

        // Only send first 15 to Apple AI, pass through the rest as-is
        let capped = Array(entities.prefix(15))
        let overflow = entities.dropFirst(15).map {
            EnrichedEntity(name: $0.name, type: $0.type, contextLabel: "")
        }
        let instructions = """
            You are a named entity classifier. For each entity, confirm or correct its type \
            (person, organization, place, product, event) and provide a one-word context label \
            (e.g. "tech company", "city", "CEO"). Return the corrected name if there are obvious typos.
            """

        var prompt = "Refine these entities:\n\n"
        for (i, entity) in capped.enumerated() {
            prompt += "[\(i)] \(entity.name) (detected as: \(entity.type))\n"
        }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: AIEntityBatchResult.self)

            // Build index-aligned result array so caller can map by position
            var enriched: [EnrichedEntity?] = Array(repeating: nil, count: capped.count)
            for refinement in response.content.results {
                guard refinement.index >= 0, refinement.index < capped.count else { continue }
                let typeStr: String
                switch refinement.entityType {
                case .person: typeStr = "Person"
                case .organization: typeStr = "Organization"
                case .place: typeStr = "Place"
                case .product: typeStr = "Product"
                case .event: typeStr = "Event"
                }
                enriched[refinement.index] = EnrichedEntity(
                    name: refinement.correctedName.isEmpty ? capped[refinement.index].name : refinement.correctedName,
                    type: typeStr,
                    contextLabel: refinement.contextLabel
                )
            }

            // Fill gaps with NLP originals, append overflow entities
            let aiResults = enriched.enumerated().map { i, entity in
                entity ?? EnrichedEntity(name: capped[i].name, type: capped[i].type, contextLabel: "")
            }
            return aiResults + overflow
        } catch {
            return entities.map { EnrichedEntity(name: $0.name, type: $0.type, contextLabel: "") }
        }
    }

    // MARK: - Language Detection Fallback (NLP low confidence → Apple AI)

    static func detectLanguage(text: String) async -> String? {
        guard isAvailable, !text.isEmpty else { return nil }

        let snippet = String(text.prefix(300))
        let instructions = "You are a language identifier. Identify the primary language of the given text."

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "What language is this text written in?\n\n\(snippet)",
                generating: AILanguageResult.self
            )
            return response.content.languageName
        } catch {
            return nil
        }
    }

    // MARK: - Smart Query Pipeline

    enum QueryIntent {
        case search
        case statistics
        case sentiment
        case summary
        case security
        case triage
        case thread
        case entity
        case topicAnalysis
        case temporal
        case general

        var maxEmails: Int {
            switch self {
            case .statistics: return 0
            case .sentiment: return 8
            case .security: return 10
            case .triage: return 10
            case .thread: return 15
            case .entity: return 10
            case .search: return 10
            case .summary: return 12
            case .topicAnalysis: return 6
            case .temporal: return 8
            case .general: return 12
            }
        }

        var maxSnippetChars: Int {
            switch self {
            case .statistics: return 0
            case .sentiment: return 200
            case .security: return 300
            case .triage: return 300
            case .thread: return 400
            case .entity: return 250
            case .search: return 350
            case .summary: return 250
            case .topicAnalysis: return 200
            case .temporal: return 200
            case .general: return 300
            }
        }

        // Apple AI always gets tools — it's the brain that decides what to call
    }

    // MARK: - Semantic Conversation Memory (v2.2.3)

    struct ConversationTurn {
        let query: String
        let intent: QueryIntent
        let answerSnippet: String
        let entities: [String]
        let topics: [String]
        let queryTerms: [String]
    }

    struct SemanticFact {
        let key: String
        let value: String
        let source: String
        let timestamp: Date
        let embedding: [Double]?
    }

    private nonisolated static let fmStateQueue = DispatchQueue(label: "com.mailin.fmState")
    nonisolated(unsafe) private static var conversationHistory: [ConversationTurn] = []
    nonisolated(unsafe) private static var semanticFacts: [SemanticFact] = []
    private static let maxHistoryTurns = 10
    private static let maxSemanticFacts = 50

    static func clearConversationMemory() {
        fmStateQueue.sync {
            conversationHistory.removeAll()
            semanticFacts.removeAll()
        }
    }

    // v3.2.1: Record user feedback for expert routing learning
    static func recordUserFeedback(query: String, intent: QueryIntent, isPositive: Bool) {
        let experts = semanticSelectExperts(query, intent: intent).map(\.rawValue)
        FeedbackManager.shared.recordFeedback(intent: "\(intent)", experts: experts, isPositive: isPositive)
    }

    private static func recordTurn(query: String, intent: QueryIntent, answer: String) {
        let snippet = String(answer.prefix(200))
        let terms = EmailNLPEngine.extractSearchTerms(from: query)
        let entityPattern = /\*\*([A-Z][a-z]+(?: [A-Z][a-z]+)+)\*\*/
        var entities: [String] = []
        for match in answer.matches(of: entityPattern) {
            let name = String(match.1)
            if !entities.contains(name) { entities.append(name) }
        }
        let topicTerms = terms.filter { $0.count > 3 && !$0.contains("@") }

        // Extract 2-5 key facts from the answer using sentence scoring
        let facts = extractKeyFacts(from: answer, query: query, source: "\(intent)")

        fmStateQueue.sync {
            conversationHistory.append(ConversationTurn(
                query: query, intent: intent, answerSnippet: snippet,
                entities: Array(entities.prefix(5)),
                topics: Array(topicTerms.prefix(5)),
                queryTerms: terms
            ))
            if conversationHistory.count > maxHistoryTurns {
                conversationHistory.removeFirst(conversationHistory.count - maxHistoryTurns)
            }

            semanticFacts.append(contentsOf: facts)
            if semanticFacts.count > maxSemanticFacts {
                semanticFacts.removeFirst(semanticFacts.count - maxSemanticFacts)
            }
        }
    }

    private static func extractKeyFacts(from answer: String, query: String, source: String) -> [SemanticFact] {
        let sentences = answer.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 && $0.count < 300 }

        guard !sentences.isEmpty else { return [] }

        let scored = sentences.map { sentence -> (String, Double) in
            var score = 0.0
            let lower = sentence.lowercased()

            if lower.contains("**") { score += 2.0 }
            let numberCount = lower.filter(\.isNumber).count
            if numberCount > 0 { score += min(Double(numberCount) / 3.0, 2.0) }
            let namePattern = /[A-Z][a-z]+ [A-Z][a-z]+/
            if sentence.firstMatch(of: namePattern) != nil { score += 1.5 }
            if lower.contains("@") || lower.contains("from ") || lower.contains("sent ") { score += 1.0 }
            let actionWords = ["found", "detected", "identified", "shows", "indicates", "reveals", "total", "average"]
            for word in actionWords where lower.contains(word) { score += 0.5 }
            if lower.contains("?") { score -= 1.0 }

            return (sentence, score)
        }

        let topFacts = scored.sorted { $0.1 > $1.1 }.prefix(5)

        return topFacts.map { sentence, _ in
            let embedding = computeFactEmbedding(sentence)
            return SemanticFact(
                key: String(sentence.prefix(60)),
                value: sentence,
                source: source,
                timestamp: Date(),
                embedding: embedding
            )
        }
    }

    private static func computeFactEmbedding(_ text: String) -> [Double]? {
        guard let embeddingModel = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        return embeddingModel.vector(for: text)
    }

    static func recallFacts(about query: String, limit: Int = 3) -> [SemanticFact] {
        let factsCopy = fmStateQueue.sync { semanticFacts }
        guard !factsCopy.isEmpty else { return [] }
        guard let embeddingModel = NLEmbedding.sentenceEmbedding(for: .english) else {
            return Array(factsCopy.suffix(limit))
        }
        guard let queryVector = embeddingModel.vector(for: query) else {
            return Array(factsCopy.suffix(limit))
        }

        let scored = factsCopy.compactMap { fact -> (SemanticFact, Double)? in
            guard let factVector = fact.embedding else { return nil }
            guard factVector.count == queryVector.count else { return nil }
            var dot = 0.0, normA = 0.0, normB = 0.0
            for i in 0..<queryVector.count {
                dot += queryVector[i] * factVector[i]
                normA += queryVector[i] * queryVector[i]
                normB += factVector[i] * factVector[i]
            }
            let denom = sqrt(normA) * sqrt(normB)
            let similarity = denom > 0 ? dot / denom : 0
            return (fact, similarity)
        }

        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func conversationContext() -> String {
        let historyCopy = fmStateQueue.sync { conversationHistory }
        let factsCopy = fmStateQueue.sync { semanticFacts }
        guard !historyCopy.isEmpty && !factsCopy.isEmpty else {
            // Fallback to simple turn-based context
            guard !historyCopy.isEmpty else { return "" }
            var ctx = "CONVERSATION MEMORY:\n"
            for (i, turn) in historyCopy.suffix(5).enumerated() {
                ctx += "Turn \(i + 1): \(turn.query) [\(turn.intent)]\n"
                if !turn.entities.isEmpty {
                    ctx += "  People/Orgs: \(turn.entities.joined(separator: ", "))\n"
                }
                ctx += "  Answer: \(turn.answerSnippet)\n\n"
            }
            return ctx
        }

        // Use last turn for recency, then semantic facts for relevance
        var ctx = "CONVERSATION MEMORY:\n"

        // Last 2 turns for immediate context
        for (i, turn) in historyCopy.suffix(2).enumerated() {
            ctx += "Recent [\(i + 1)]: \(turn.query) → \(turn.answerSnippet)\n"
        }

        // Top semantic facts relevant to the recent query
        if let lastQuery = historyCopy.last?.query {
            let relevantFacts = recallFacts(about: lastQuery, limit: 3)
            if !relevantFacts.isEmpty {
                ctx += "RELEVANT FACTS:\n"
                for fact in relevantFacts {
                    ctx += "• \(fact.value)\n"
                }
            }
        }

        return ctx
    }

    // MARK: - Dual-Classification with Consensus

    struct IntentClassification {
        let intent: QueryIntent
        let confidence: ClassificationConfidence
        let embeddingIntent: QueryIntent
        let aiIntent: QueryIntent?
        let isAmbiguous: Bool
        let embeddingScores: [QueryIntent: Double]

        enum ClassificationConfidence {
            case high      // both agree, or embedding very strong
            case medium    // one source confident
            case low       // disagreement or weak scores
        }
    }

    static func classifyIntent(_ query: String) async -> QueryIntent {
        let result = await classifyIntentDual(query)
        return result.intent
    }

    static func classifyIntentDual(_ query: String) async -> IntentClassification {
        let (embeddingIntent, embeddingScores) = semanticClassifyIntent(query)
        let embeddingTopScore = embeddingScores[embeddingIntent] ?? 0

        let aiIntent = await classifyIntentWithAI(query)

        // Consensus logic
        if let ai = aiIntent {
            if ai == embeddingIntent {
                // Both agree → high confidence
                return IntentClassification(
                    intent: ai, confidence: .high,
                    embeddingIntent: embeddingIntent, aiIntent: ai,
                    isAmbiguous: false, embeddingScores: embeddingScores
                )
            } else {
                // Disagree → Apple AI wins, but mark as ambiguous
                return IntentClassification(
                    intent: ai, confidence: .low,
                    embeddingIntent: embeddingIntent, aiIntent: ai,
                    isAmbiguous: true, embeddingScores: embeddingScores
                )
            }
        }

        // Apple AI unavailable → NLEmbedding only
        let confidence: IntentClassification.ClassificationConfidence = embeddingTopScore > 0.45 ? .high : .medium
        return IntentClassification(
            intent: embeddingIntent, confidence: confidence,
            embeddingIntent: embeddingIntent, aiIntent: nil,
            isAmbiguous: false, embeddingScores: embeddingScores
        )
    }

    private static func classifyIntentWithAI(_ query: String) async -> QueryIntent? {
        guard isAvailable else { return nil }
        do {
            let instructions = """
                Classify this question about an email archive into one category. \
                search: finding specific emails. statistics: counts, numbers, percentages. \
                sentiment: emotional tone or mood. summary: overview or digest. \
                security: phishing, scams, PII. triage: priority, urgency, action items. \
                thread: conversation flow, discussion history. entity: about a person or org. \
                topicAnalysis: themes, keywords, topics. temporal: trends over time. \
                general: anything else. Also extract key search terms and detect follow-ups.
                """
            var prompt = "Classify: \(query)"
            if let lastTurn = conversationHistory.last {
                prompt += "\nPrevious question was: \(lastTurn.query)"
            }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: AIIntentResult.self)
            let result = response.content

            let mapped: QueryIntent
            switch result.intent {
            case .search: mapped = .search
            case .statistics: mapped = .statistics
            case .sentiment: mapped = .sentiment
            case .summary: mapped = .summary
            case .security: mapped = .security
            case .triage: mapped = .triage
            case .thread: mapped = .thread
            case .entity: mapped = .entity
            case .topicAnalysis: mapped = .topicAnalysis
            case .temporal: mapped = .temporal
            case .general: mapped = .general
            }
            return mapped
        } catch {
            return nil
        }
    }

    static func classifyConversationalIntent(_ query: String) async -> AIConversationalType? {
        guard isAvailable else { return nil }
        do {
            let instructions = """
                You are an assistant embedded in an email archive app. Classify the user's message. \
                greeting: hello, hi, how are you, good morning, what can you do, help me, etc. \
                acknowledgment: ok, thanks, cool, great, got it, nice, yes, no, lol, etc. \
                capability: asking what you can do, your features, how you work. \
                emailQuery: anything about emails, searching, analyzing, filtering, summarizing, or any substantive question.
                """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: query, generating: AIConversationalClassification.self)
            return response.content.messageType
        } catch {
            return nil
        }
    }

    static func generateConversationalResponse(_ query: String, emailCount: Int) async -> String? {
        guard isAvailable else { return nil }
        do {
            let instructions = """
                Email assistant in mailin (on-device, private). \(emailCount) emails loaded. \
                If conversational (greeting, about-you), respond in 2-3 sentences. \
                If asking about emails, set isConversational=false, response empty.
                """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: query, generating: AIConversationalResponse.self)
            let result = response.content
            if result.isConversational && !result.response.isEmpty {
                return result.response
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func classifyIntentKeyword(_ query: String) -> QueryIntent {
        let q = query.lowercased()

        if q.contains("how many") || q.contains("count") || q.contains("total number") ||
           q.contains("percentage") || q.contains("ratio") || q.contains("statistics") ||
           q.contains("breakdown") || q.contains("distribution") {
            if !q.contains("sentiment") && !q.contains("tone") { return .statistics }
        }

        if q.contains("phishing") || q.contains("suspicious") || q.contains("scam") ||
           q.contains("spam") || q.contains("fraud") || q.contains("pii") ||
           q.contains("sensitive data") || q.contains("malware") || q.contains("threat") ||
           q.contains("dangerous") || q.contains("safe") || q.contains("legitimate") ||
           (q.contains("security") && q.contains("email")) {
            return .security
        }

        if q.contains("sentiment") || q.contains("tone") || q.contains("mood") ||
           q.contains("feeling") || q.contains("emotion") || q.contains("angry") ||
           q.contains("happy") || q.contains("upset") || q.contains("frustrated") ||
           q.contains("positive") || q.contains("negative") {
            if q.contains("positive") || q.contains("negative") {
                if q.contains("email") || q.contains("message") || q.contains("tone") { return .sentiment }
            } else {
                return .sentiment
            }
        }

        if q.contains("thread") || q.contains("conversation about") || q.contains("discussion about") ||
           q.contains("what happened with") || q.contains("reply chain") || q.contains("replies") {
            return .thread
        }

        if q.contains("triage") || q.contains("priority") || q.contains("urgent") ||
           q.contains("deadline") || q.contains("overdue") || q.contains("action item") ||
           q.contains("follow up") || q.contains("respond to") ||
           ((q.contains("important") || q.contains("action")) && q.contains("email")) {
            return .triage
        }

        if (q.contains("who") && (q.contains("most") || q.contains("frequently") || q.contains("contact") || q.contains("sent") || q.contains("email"))) ||
           q.contains("people") || q.contains("contacts") || q.contains("sender") ||
           q.contains("person") || q.contains("organization") {
            return .entity
        }

        if q.contains("topic") || q.contains("theme") || q.contains("keyword") ||
           q.contains("discuss") || q.contains("about what") || q.contains("talk about") ||
           q.contains("categories") || q.contains("categorize") || q.contains("classify") {
            return .topicAnalysis
        }

        if q.contains("trend") || q.contains("over time") || q.contains("pattern") ||
           q.contains("weekly") || q.contains("monthly") || q.contains("daily") ||
           q.contains("timeline") || q.contains("chronolog") || q.contains("when") {
            if q.contains("when") && !q.contains("when did") && !q.contains("when was") {
                return .temporal
            } else if q.contains("when") {
                return .temporal
            } else {
                return .temporal
            }
        }

        if q.contains("summarize") || q.contains("summary") || q.contains("overview") ||
           q.contains("digest") || q.contains("brief me") || q.contains("recap") ||
           q.contains("key takeaway") || q.contains("highlight") {
            return .summary
        }

        if q.contains("find") || q.contains("search") || q.contains("show me") ||
           q.contains("look for") || q.contains("emails about") || q.contains("emails from") ||
           q.contains("messages from") || q.contains("locate") || q.contains("where is") {
            return .search
        }

        return .general
    }

    // MARK: - Query Understanding Layer
    // Uses Apple NLP (NLEmbedding, NLTagger) to understand user intent BEFORE the AI model.
    // Apple's on-device model is small (~3B params) — this NLP layer does the understanding;
    // the model does the synthesis.

    struct ParsedQuery {
        let original: String
        let action: QueryAction
        let entities: [String]
        let timeRef: String?
        let senderRef: String?
        let topicRef: String?
        let semanticIntent: QueryIntent
        let expertScores: [ExpertRole: Double]
        let rewrittenPrompt: String
    }

    enum QueryAction: String {
        case check, find, count, analyze, compare, list, scan, summarize, explain, ask
    }

    // MARK: - Semantic Intent Classification via NLEmbedding

    private static let intentEmbeddingPhrases: [QueryIntent: [String]] = [
        .sentiment: [
            "emotional tone mood feeling angry happy upset positive negative",
            "how does someone feel about this",
            "tone of the conversation relationship warmth hostility",
            "are they angry frustrated pleased satisfied",
            "sentiment analysis emotional state"
        ],
        .entity: [
            "who is this person contact sender receiver",
            "people organizations companies mentioned",
            "who sent the most emails key contacts",
            "relationship between people communication partners",
            "names people involved participants"
        ],
        .security: [
            "phishing scam suspicious fraud spam malware",
            "is this email safe legitimate trustworthy",
            "sensitive data exposure personal information leak",
            "security threat risk dangerous links",
            "social engineering impersonation fake"
        ],
        .topicAnalysis: [
            "what topics themes subjects are discussed",
            "main themes keywords categories",
            "what are they talking about discussing",
            "subject matter content analysis themes",
            "categorize classify emails by topic"
        ],
        .temporal: [
            "when over time trend pattern timeline",
            "email volume frequency daily weekly monthly",
            "busiest period peak quiet time",
            "date range oldest newest chronological",
            "how has it changed over time"
        ],
        .statistics: [
            "how many count total number percentage",
            "statistics breakdown distribution ratio",
            "quantify measure numbers data figures",
            "average median volume amount",
            "email count metrics analytics"
        ],
        .summary: [
            "summarize overview digest brief recap",
            "give me a summary of what is happening",
            "key takeaways highlights important points",
            "what should I know overall picture",
            "brief me on the situation"
        ],
        .triage: [
            "urgent priority action items important",
            "what needs attention immediately",
            "which emails are most important",
            "deadline overdue follow up required",
            "what should I respond to first"
        ],
        .thread: [
            "conversation thread discussion chain replies",
            "what happened in this thread",
            "follow the conversation flow",
            "reply chain discussion history",
            "how did this conversation evolve"
        ],
        .search: [
            "find search look for locate show me",
            "emails about emails from emails containing",
            "where is the email with specific content",
            "filter emails matching criteria",
            "search for specific emails"
        ],
        .general: [
            "tell me about help explain what",
            "general question about my emails",
            "analyze my email archive"
        ]
    ]

    private static let expertDomainPhrases: [ExpertRole: [String]] = [
        .sentimentExpert: [
            "emotional tone feeling mood sentiment positive negative angry happy",
            "relationship warmth cooling hostility passive aggressive",
            "how does someone feel satisfaction frustration",
            "tone shift emotional change attitude"
        ],
        .entityExpert: [
            "people person contact sender who organization company",
            "names relationships connections communication partners",
            "key contacts decision makers influential people",
            "who is involved participants team members",
            "domain distribution sender analysis"
        ],
        .topicExpert: [
            "topic theme subject keyword category discussion",
            "what are they talking about content analysis",
            "main themes categorize classify emails",
            "subject matter topics covered areas discussed"
        ],
        .timelineExpert: [
            "when time date trend pattern chronological timeline",
            "over time daily weekly monthly volume frequency",
            "busiest period peak quiet date range",
            "temporal pattern schedule rhythm cadence"
        ],
        .securityExpert: [
            "phishing scam suspicious fraud spam malware security",
            "safe legitimate trustworthy dangerous threat risk",
            "sensitive data personal information exposure PII",
            "social engineering impersonation fake deception"
        ]
    ]

    private static func semanticClassifyIntent(_ query: String) -> (intent: QueryIntent, scores: [QueryIntent: Double]) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return (classifyIntentKeyword(query), [:])
        }

        var intentScores: [QueryIntent: Double] = [:]
        for (intent, phrases) in intentEmbeddingPhrases {
            var bestSim = -1.0
            for phrase in phrases {
                let distance = embedding.distance(between: query.lowercased(), and: phrase)
                let similarity = 1.0 - distance
                bestSim = max(bestSim, similarity)
            }
            intentScores[intent] = bestSim
        }

        let sorted = intentScores.sorted { $0.value > $1.value }
        let topIntent = sorted.first?.key ?? .general
        let topScore = sorted.first?.value ?? 0

        if topScore < 0.3 {
            return (classifyIntentKeyword(query), intentScores)
        }

        return (topIntent, intentScores)
    }

    private static func semanticSelectExperts(_ query: String, intent: QueryIntent) -> [ExpertRole] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return selectExperts(for: intent)
        }

        var expertScores: [ExpertRole: Double] = [:]
        for (role, phrases) in expertDomainPhrases {
            var bestSim = -1.0
            for phrase in phrases {
                let distance = embedding.distance(between: query.lowercased(), and: phrase)
                let similarity = 1.0 - distance
                bestSim = max(bestSim, similarity)
            }
            expertScores[role] = bestSim
        }

        // v3.2.1: Apply feedback-driven weight multipliers
        let intentKey = "\(intent)"
        for role in expertScores.keys {
            let multiplier = FeedbackManager.shared.weightMultiplier(intent: intentKey, expert: role.rawValue)
            expertScores[role] = (expertScores[role] ?? 0) * multiplier
        }

        // v4.3.1: Apply persona-specific expert weight multipliers
        let currentPersona = PersonaManager.Persona(rawValue: UserDefaults.standard.string(forKey: "selectedPersona") ?? "general") ?? .general
        let personaWeights = PersonaManager.aiConfig(for: currentPersona).expertWeights
        for role in expertScores.keys {
            if let personaWeight = personaWeights[role.rawValue] {
                expertScores[role] = (expertScores[role] ?? 0) * personaWeight
            }
        }

        let sorted = expertScores.sorted { $0.value > $1.value }
        var selected: [ExpertRole] = []
        for (role, score) in sorted {
            if score > 0.25 && selected.count < 4 {
                selected.append(role)
            }
        }

        if selected.isEmpty {
            return selectExperts(for: intent)
        }
        return selected
    }

    // v3.5.1: Get custom experts that match the query
    static func matchingCustomExperts(for query: String, maxCount: Int = 2) -> [CustomExpert] {
        let scored = CustomExpertManager.shared.scoreExperts(query: query)
        return scored.filter { $0.score > 0.25 }.prefix(maxCount).map(\.expert)
    }

    // v3.5.1: Run a custom expert with user-defined instructions
    private static func runCustomExpertStructured(
        expert: CustomExpert,
        query: String,
        emails: [MBOXParser.RawEmail]
    ) async -> AISessionFindings {
        let terms = expert.keywords + EmailNLPEngine.extractSearchTerms(from: query)
        let relevant = EmailSearchIndex.shared.hybridSearch(query: terms.joined(separator: " "), terms: terms, limit: 15).map(\.email)
        let emailsToUse = relevant.isEmpty ? Array(emails.prefix(15)) : relevant

        var context = "CUSTOM EXPERT: \(expert.name)\n"
        context += "KEYWORDS: \(expert.keywords.joined(separator: ", "))\n"
        context += "EMAILS (\(emailsToUse.count)):\n"
        for email in emailsToUse.prefix(10) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let date = email.headers["Date"] ?? ""
            let body = bodySnippet(for: email, maxLength: 200)
            context += "--- \(subj) ---\nFrom: \(from)\nDate: \(date)\nBody: \(body)\n\n"
        }

        guard isAvailable else {
            return AISessionFindings(
                findings: [AIFinding(finding: "Custom expert '\(expert.name)' analyzed \(emailsToUse.count) emails.", evidence: "", relevance: .medium)],
                summary: "\(expert.name): \(context.prefix(100))",
                confidence: 2
            )
        }

        do {
            let session = LanguageModelSession(instructions:
                expert.instructions + " " +
                "Analyze the data and produce structured findings. " +
                "Each finding must be one specific, evidence-backed sentence. " +
                "Rate relevance: high = directly answers the question, medium = useful context, low = tangential."
            )
            let truncatedContext = String(context.prefix(3000))
            let response = try await session.respond(
                to: "Question: \(query)\n\nData:\n\(truncatedContext)",
                generating: AISessionFindings.self
            )
            return response.content
        } catch {
            return AISessionFindings(
                findings: [AIFinding(finding: "\(expert.name): \(String(context.prefix(200)))", evidence: "", relevance: .medium)],
                summary: "\(expert.name) analysis",
                confidence: 2
            )
        }
    }

    static func understandQuery(_ query: String, emails: [MBOXParser.RawEmail]) -> ParsedQuery {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split(separator: " ").map(String.init)

        // 1. Extract ACTION
        let action: QueryAction
        if words.first(where: { ["check", "verify", "validate", "inspect", "audit"].contains($0) }) != nil {
            action = .check
        } else if words.first(where: { ["find", "search", "look", "locate", "show", "get", "give"].contains($0) }) != nil {
            action = .find
        } else if words.first(where: { ["how many", "count", "total", "number"].contains($0) }) != nil || lower.contains("how many") {
            action = .count
        } else if words.first(where: { ["analyze", "analyse", "assess", "evaluate", "review"].contains($0) }) != nil {
            action = .analyze
        } else if words.first(where: { ["compare", "versus", "vs", "difference", "between"].contains($0) }) != nil {
            action = .compare
        } else if words.first(where: { ["list", "all", "every", "each"].contains($0) }) != nil {
            action = .list
        } else if words.first(where: { ["scan", "detect", "flag", "identify"].contains($0) }) != nil {
            action = .scan
        } else if words.first(where: { ["summarize", "summary", "overview", "brief", "digest"].contains($0) }) != nil {
            action = .summarize
        } else if words.first(where: { ["explain", "why", "what", "how", "tell"].contains($0) }) != nil {
            action = .explain
        } else {
            action = .ask
        }

        // 2. Extract ENTITIES using NLTagger
        var entities: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = query
        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if let tag, tag == .personalName || tag == .organizationName || tag == .placeName {
                let entity = String(query[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if entity.count > 1 { entities.append(entity) }
            }
            return true
        }

        // 3. Extract TIME references
        let timePatterns = ["last week", "last month", "last year", "this week", "this month", "this year",
                           "yesterday", "today", "recent", "latest", "oldest", "newest",
                           "january", "february", "march", "april", "may", "june",
                           "july", "august", "september", "october", "november", "december",
                           "q1", "q2", "q3", "q4", "2023", "2024", "2025", "2026"]
        let timeRef = timePatterns.first(where: { lower.contains($0) })

        // 4. Extract SENDER references ("from X", "by X", "sent by X")
        var senderRef: String?
        let senderPatterns = [
            try? NSRegularExpression(pattern: "(?:from|by|sent by|emails? from|messages? from)\\s+([\\w.@]+(?:\\s+\\w+)?)", options: .caseInsensitive)
        ].compactMap { $0 }
        for regex in senderPatterns {
            if let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) {
                if let range = Range(match.range(at: 1), in: query) {
                    senderRef = String(query[range]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // 5. Extract TOPIC references ("about X", "regarding X", "related to X")
        var topicRef: String?
        let topicPatterns = [
            try? NSRegularExpression(pattern: "(?:about|regarding|related to|concerning|on the topic of)\\s+(.+?)(?:\\s*\\?|$)", options: .caseInsensitive)
        ].compactMap { $0 }
        for regex in topicPatterns {
            if let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) {
                if let range = Range(match.range(at: 1), in: query) {
                    topicRef = String(query[range]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // 6. Semantic intent classification via NLEmbedding
        let (semanticIntent, _) = semanticClassifyIntent(query)

        // 7. Semantic expert scoring via NLEmbedding
        var expertScores: [ExpertRole: Double] = [:]
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            for (role, phrases) in expertDomainPhrases {
                var bestSim = -1.0
                for phrase in phrases {
                    let distance = embedding.distance(between: lower, and: phrase)
                    let similarity = 1.0 - distance
                    bestSim = max(bestSim, similarity)
                }
                expertScores[role] = bestSim
            }
        }

        // 8. Rewrite query as structured prompt enriched with semantic understanding
        var parts: [String] = []
        parts.append("Task: \(action.rawValue)")
        parts.append("Intent: \(semanticIntent)")
        if let sender = senderRef { parts.append("Sender: \(sender)") }
        if let topic = topicRef { parts.append("Topic: \(topic)") }
        if let time = timeRef { parts.append("Time: \(time)") }
        if !entities.isEmpty { parts.append("Entities: \(entities.joined(separator: ", "))") }
        parts.append("Question: \(query)")

        return ParsedQuery(
            original: query,
            action: action,
            entities: entities,
            timeRef: timeRef,
            senderRef: senderRef,
            topicRef: topicRef,
            semanticIntent: semanticIntent,
            expertScores: expertScores,
            rewrittenPrompt: parts.joined(separator: "\n")
        )
    }

    private static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    // The usable context budget: 4096 total minus instructions, tools, query, and response space
    private static let contextCharBudget = 9000

    // MARK: - Dynamic Intent-Aware Context Budget (v2.1.2)

    struct ContextBudget {
        let profileChars: Int
        let emailBodyChars: Int
        let headerChars: Int
        let findingsChars: Int
        let ragChars: Int
        let conversationChars: Int

        var total: Int { profileChars + emailBodyChars + headerChars + findingsChars + ragChars + conversationChars }
    }

    private static func contextBudget(for intent: QueryIntent) -> ContextBudget {
        let total = contextCharBudget
        switch intent {
        case .security:
            // Security needs deep header analysis, moderate body for phishing content
            return ContextBudget(
                profileChars: total / 8,        // 1125
                emailBodyChars: total / 4,       // 2250
                headerChars: total * 3 / 10,     // 2700 — headers are primary evidence
                findingsChars: total / 5,        // 1800
                ragChars: total / 10,            // 900
                conversationChars: 400
            )
        case .sentiment:
            // Sentiment needs maximal body text for tone/emotion analysis
            return ContextBudget(
                profileChars: total / 8,         // 1125
                emailBodyChars: total * 2 / 5,   // 3600 — body is primary evidence
                headerChars: total / 15,         // 600
                findingsChars: total / 5,        // 1800
                ragChars: total / 8,             // 1125
                conversationChars: 400
            )
        case .entity:
            // Entity needs balanced body + headers for people/org extraction
            return ContextBudget(
                profileChars: total / 8,         // 1125
                emailBodyChars: total * 3 / 10,  // 2700
                headerChars: total / 5,          // 1800 — From/To/Cc are critical
                findingsChars: total / 5,        // 1800
                ragChars: total / 10,            // 900
                conversationChars: 400
            )
        case .temporal:
            // Timeline needs header dates, weekly/hourly patterns
            return ContextBudget(
                profileChars: total / 8,         // 1125
                emailBodyChars: total / 6,       // 1500
                headerChars: total * 3 / 10,     // 2700 — dates and routing info
                findingsChars: total / 4,        // 2250 — timeline findings are dense
                ragChars: total / 12,            // 750
                conversationChars: 400
            )
        case .topicAnalysis:
            // Topics need maximal body text for theme extraction
            return ContextBudget(
                profileChars: total / 8,         // 1125
                emailBodyChars: total * 2 / 5,   // 3600 — body is primary
                headerChars: total / 15,         // 600
                findingsChars: total / 5,        // 1800
                ragChars: total / 8,             // 1125
                conversationChars: 400
            )
        case .thread:
            // Threading needs body for conversation context, moderate headers
            return ContextBudget(
                profileChars: total / 10,        // 900
                emailBodyChars: total * 3 / 10,  // 2700 — thread body content
                headerChars: total / 6,          // 1500 — References/In-Reply-To
                findingsChars: total / 5,        // 1800
                ragChars: total / 8,             // 1125
                conversationChars: 400
            )
        case .triage:
            // Triage needs balanced view — urgency from body + headers
            return ContextBudget(
                profileChars: total / 8,         // 1125
                emailBodyChars: total * 3 / 10,  // 2700
                headerChars: total / 6,          // 1500
                findingsChars: total / 5,        // 1800
                ragChars: total / 10,            // 900
                conversationChars: 400
            )
        case .statistics:
            // Stats need minimal body, maximal findings space
            return ContextBudget(
                profileChars: total / 6,         // 1500
                emailBodyChars: 0,
                headerChars: 0,
                findingsChars: total * 2 / 5,    // 3600 — NLP stats are the context
                ragChars: total / 10,            // 900
                conversationChars: 400
            )
        case .search, .summary, .general:
            // Balanced defaults
            return ContextBudget(
                profileChars: total / 6,         // 1500
                emailBodyChars: total * 3 / 10,  // 2700
                headerChars: total / 10,         // 900
                findingsChars: total / 5,        // 1800
                ragChars: total / 10,            // 900
                conversationChars: 400
            )
        }
    }

    private static func selectTools(
        for intent: QueryIntent,
        emails: [MBOXParser.RawEmail]
    ) -> [any Tool] {
        var tools: [any Tool] = []

        switch intent {
        case .entity:
            tools.append(SenderProfileTool(emails: emails))
            tools.append(ContactLookupTool())
            tools.append(CalendarCheckTool())
            tools.append(SpotlightSearchTool())
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(KnowledgeGraphQueryTool())

        case .triage:
            tools.append(CalendarCheckTool())
            tools.append(SenderProfileTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))

        case .security:
            tools.append(PhishingAnalysisTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(AttachmentAnalysisTool(emails: emails))

        case .search:
            tools.append(SpotlightSearchTool())
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(GetThreadInfoTool(emails: emails))
            tools.append(ContactLookupTool())
            tools.append(TopicDrillTool(emails: emails))
            tools.append(AttachmentAnalysisTool(emails: emails))
            tools.append(KnowledgeGraphQueryTool())

        case .thread:
            tools.append(GetThreadInfoTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))
            tools.append(SpotlightSearchTool())
            tools.append(KnowledgeGraphQueryTool())

        case .summary:
            tools.append(TopicDrillTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(SpotlightSearchTool())
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(KnowledgeGraphQueryTool())

        case .sentiment:
            tools.append(SenderProfileTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))

        case .topicAnalysis:
            tools.append(TopicDrillTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(KnowledgeGraphQueryTool())

        case .general:
            tools.append(SpotlightSearchTool())
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(GetThreadInfoTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))
            tools.append(TopicDrillTool(emails: emails))
            tools.append(ContactLookupTool())
            tools.append(CalendarCheckTool())
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(PhishingAnalysisTool(emails: emails))
            tools.append(AttachmentAnalysisTool(emails: emails))
            tools.append(VisualizationRecommendTool())
            tools.append(KnowledgeGraphQueryTool())

        case .statistics:
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(TopicDrillTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))

        case .temporal:
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(TopicDrillTool(emails: emails))
        }

        return tools
    }

    // MARK: - Archive Profile (pre-computed stats over ALL emails)

    nonisolated(unsafe) private static var cachedProfile: (count: Int, profile: String)?

    static func invalidateProfileCache() {
        fmStateQueue.sync { cachedProfile = nil }
    }

    private static func archiveProfile(emails: [MBOXParser.RawEmail]) -> String {
        let cached = fmStateQueue.sync { cachedProfile }
        if let cached, cached.count == emails.count {
            return cached.profile
        }

        var p = "ARCHIVE PROFILE (\(emails.count) emails):\n"
        let f = DateFormatter(); f.dateStyle = .medium

        // --- Basic stats ---
        let sent = emails.filter { $0.messageType == "sent" }.count
        let recv = emails.filter { $0.messageType == "received" }.count
        p += "Sent: \(sent), Received: \(recv)\n"

        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        if let first = dates.first, let last = dates.last {
            p += "Period: \(f.string(from: first)) to \(f.string(from: last))\n"
        }

        // --- Per-sender profiles (top 15 with sentiment + topics) ---
        var senderEmails: [String: [MBOXParser.RawEmail]] = [:]
        for email in emails {
            let from = email.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
            senderEmails[from, default: []].append(email)
        }
        let topSenders = senderEmails.sorted { $0.value.count > $1.value.count }.prefix(15)
        p += "\nTOP SENDERS:\n"
        for (sender, senderMails) in topSenders {
            let count = senderMails.count
            let sentiment = EmailNLPEngine.averageSentiment(of: senderMails)
            let subjects = senderMails.prefix(3).compactMap { $0.headers["Subject"] }
            let senderDates = senderMails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            var line = "• \(sender): \(count) emails, \(sentiment.label)"
            if let last = senderDates.last { line += ", last: \(f.string(from: last))" }
            if !subjects.isEmpty { line += ", e.g. \"\(subjects[0])\"" }
            p += line + "\n"
        }

        // --- Topic clusters with representative subjects ---
        let topics = EmailNLPEngine.extractTopics(from: emails, limit: 15)
        if !topics.isEmpty {
            p += "\nTOPIC MAP:\n"
            for topic in topics {
                let matching = emails.filter {
                    ($0.headers["Subject"] ?? "").lowercased().contains(topic.word.lowercased()) ||
                    $0.plainBody.lowercased().contains(topic.word.lowercased())
                }
                let exampleSubjects = matching.prefix(2).compactMap { $0.headers["Subject"] }
                var line = "• \(topic.word) (\(topic.count)x)"
                if !exampleSubjects.isEmpty {
                    line += ": \"\(exampleSubjects.joined(separator: "\", \""))\""
                }
                p += line + "\n"
            }
        }

        // --- Time-period breakdown ---
        if dates.count >= 10 {
            p += "\nTIMELINE:\n"
            let cal = Calendar.current
            var monthBuckets: [(label: String, count: Int, topSubject: String)] = []
            var monthEmails: [String: [MBOXParser.RawEmail]] = [:]
            for email in emails {
                guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
                let components = cal.dateComponents([.year, .month], from: date)
                let key = "\(components.year ?? 0)-\(String(format: "%02d", components.month ?? 0))"
                monthEmails[key, default: []].append(email)
            }
            let sortedMonths = monthEmails.sorted { $0.key < $1.key }
            for (key, mails) in sortedMonths.suffix(6) {
                let topSubj = mails.first?.headers["Subject"] ?? ""
                monthBuckets.append((label: key, count: mails.count, topSubject: topSubj))
            }
            for bucket in monthBuckets {
                p += "• \(bucket.label): \(bucket.count) emails"
                if !bucket.topSubject.isEmpty { p += ", e.g. \"\(bucket.topSubject)\"" }
                p += "\n"
            }
        }

        // --- Key threads ---
        let threads = ThreadGrouper.group(emails)
        let multiThreads = threads.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        p += "\nKEY THREADS (\(threads.count) total, \(multiThreads.count) multi-email):\n"
        for thread in multiThreads.prefix(8) {
            let participants = Set(thread.allEmails.compactMap { $0.headers["From"] }).count
            let threadDates = thread.allEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            var line = "• \"\(thread.subject)\" — \(thread.count) emails, \(participants) people"
            if let first = threadDates.first, let last = threadDates.last {
                line += ", \(f.string(from: first))–\(f.string(from: last))"
            }
            p += line + "\n"
        }

        // --- Categories + Sentiment ---
        let cls = EmailNLPEngine.classifyAll(emails)
        let catStrs = EmailNLPEngine.EmailCategory.allCases.compactMap { c -> String? in
            guard let n = cls[c], n > 0 else { return nil }; return "\(c.rawValue): \(n)"
        }
        if !catStrs.isEmpty { p += "\nCategories: " + catStrs.joined(separator: ", ") + "\n" }

        let s = EmailNLPEngine.averageSentiment(of: emails)
        p += "Overall sentiment: \(s.label) (avg \(String(format: "%.2f", s.average))). +\(s.positive)/~\(s.neutral)/-\(s.negative)\n"

        // --- Entities ---
        let entities = EmailNLPEngine.extractEntities(from: emails, limit: 12)
        if !entities.isEmpty {
            p += "Entities: " + entities.map { "\($0.name) (\($0.type), \($0.count)x)" }.joined(separator: ", ") + "\n"
        }

        fmStateQueue.sync { cachedProfile = (count: emails.count, profile: p) }
        return p
    }

    // MARK: - 1. Speculative Pre-computation (background, runs on import)

    nonisolated(unsafe) private static var precomputedSenderProfiles: [(sender: String, count: Int, sentiment: String, topics: [String])] = []
    nonisolated(unsafe) private static var precomputedSecurityScan: (phishingCount: Int, piiTypes: [String])? = nil
    nonisolated(unsafe) private static var precomputedTopicClusters: [(topic: String, count: Int, senders: [String])] = []
    nonisolated(unsafe) private static var precomputedTimeline: [(month: String, count: Int)] = []
    nonisolated(unsafe) private static var precomputationDone = false
    nonisolated(unsafe) private static var knowledgeGraph: KnowledgeGraph?

    // v3.4.1: Proactive findings from background import analysis
    struct ProactiveFinding: Sendable {
        let category: String
        let severity: Double
        let title: String
        let detail: String
        let emailIDs: [UUID]
    }
    nonisolated(unsafe) private static var proactiveFindings: [ProactiveFinding] = []

    static func getProactiveFindings() -> [ProactiveFinding] {
        fmStateQueue.sync { proactiveFindings }
    }

    // v4.5.1: Allow background analysis to update knowledge graph
    static func setKnowledgeGraph(_ graph: KnowledgeGraph) {
        fmStateQueue.sync { knowledgeGraph = graph }
    }

    static func precomputeOnImport(emails: [MBOXParser.RawEmail]) {
        guard !emails.isEmpty else { return }

        Task.detached(priority: .utility) {
            // Pre-build archive profile (cached for instant access)
            _ = archiveProfile(emails: emails)

            // Pre-compute top sender profiles
            var senderMap: [String: [MBOXParser.RawEmail]] = [:]
            for email in emails {
                let from = email.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
                senderMap[from, default: []].append(email)
            }
            let topSenders = senderMap.sorted { $0.value.count > $1.value.count }.prefix(10)
            var senderProfiles: [(sender: String, count: Int, sentiment: String, topics: [String])] = []
            for (sender, sEmails) in topSenders {
                let s = EmailNLPEngine.averageSentiment(of: sEmails)
                let t = EmailNLPEngine.extractTopics(from: sEmails, limit: 3)
                senderProfiles.append((sender: sender, count: sEmails.count, sentiment: s.label, topics: t.map(\.word)))
            }

            // Pre-compute topic clusters
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 12)
            var clusters: [(topic: String, count: Int, senders: [String])] = []
            for topic in topics {
                let matching = emails.filter {
                    ($0.headers["Subject"] ?? "").lowercased().contains(topic.word.lowercased()) ||
                    $0.plainBody.lowercased().contains(topic.word.lowercased())
                }
                let topS = Dictionary(grouping: matching, by: { $0.headers["From"] ?? "?" })
                    .sorted { $0.value.count > $1.value.count }
                    .prefix(3).map(\.key)
                clusters.append((topic: topic.word, count: topic.count, senders: topS))
            }

            // Pre-compute timeline
            let cal = Calendar.current
            var monthMap: [String: Int] = [:]
            for email in emails {
                guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
                let c = cal.dateComponents([.year, .month], from: date)
                let key = "\(c.year ?? 0)-\(String(format: "%02d", c.month ?? 0))"
                monthMap[key, default: 0] += 1
            }
            let timeline = monthMap.sorted { $0.key < $1.key }.map { (month: $0.key, count: $0.value) }

            // Pre-compute security scan
            let phishing = EmailNLPEngine.detectPhishing(in: emails)
            let pii = EmailNLPEngine.piiSummary(in: emails)
            let secScan = (phishingCount: phishing.count, piiTypes: pii.map { $0.key.rawValue })

            let finalSenders = senderProfiles
            let finalClusters = clusters
            fmStateQueue.sync {
                precomputedSenderProfiles = finalSenders
                precomputedTopicClusters = finalClusters
                precomputedTimeline = timeline
                precomputedSecurityScan = secScan
                precomputationDone = true
            }

            // v3.1.2: Build knowledge graph alongside existing precomputation
            let graph = KnowledgeGraph.load()
            KnowledgeGraphBuilder.build(from: emails, into: graph)
            fmStateQueue.sync {
                knowledgeGraph = graph
            }

            // v3.4.1: Proactive background analysis — anomalies, phishing, sentiment shifts, PII
            let findings = runProactiveScan(emails: emails, phishingResults: phishing, piiResults: pii)
            fmStateQueue.sync {
                proactiveFindings = findings
            }

            // Send local notifications for high-severity findings
            let notifiable = findings.filter { $0.severity >= 0.5 }
            if !notifiable.isEmpty {
                Task { @MainActor in
                    let manager = SmartNotificationManager()
                    manager.requestAuthorization()
                    for finding in notifiable {
                        let alertType: SmartAlertType
                        switch finding.category {
                        case "phishing": alertType = .phishingDetected
                        case "pii": alertType = .piiExposure
                        case "sentiment": alertType = .sentimentShift
                        case "volume": alertType = .unusualVolume
                        default: alertType = .newSenderBurst
                        }
                        let severity: SmartAlertSeverity = finding.severity >= 0.8 ? .high : .medium
                        let alert = SmartAlert(
                            type: alertType, severity: severity,
                            title: finding.title, message: finding.detail,
                            emailIDs: finding.emailIDs
                        )
                        manager.sendLocalNotification(for: alert)
                    }
                }
            }
        }
    }

    // v3.4.1: Proactive scan runs during import, surfaces noteworthy findings
    private static func runProactiveScan(
        emails: [MBOXParser.RawEmail],
        phishingResults: [EmailNLPEngine.PhishingFlag],
        piiResults: [EmailNLPEngine.PIIType: Int]
    ) -> [ProactiveFinding] {
        var findings: [ProactiveFinding] = []

        // 1. Anomaly detection
        let anomalies = AnomalyDetectionEngine.detectAnomalies(in: emails)
        for anomaly in anomalies where anomaly.severity >= 0.4 {
            findings.append(ProactiveFinding(
                category: anomaly.type.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"),
                severity: anomaly.severity,
                title: anomaly.title,
                detail: anomaly.detail,
                emailIDs: anomaly.affectedEmails
            ))
        }

        // 2. Phishing summary
        let highRisk = phishingResults.filter { $0.riskLevel == .high }
        let medRisk = phishingResults.filter { $0.riskLevel == .medium }
        if !highRisk.isEmpty {
            findings.append(ProactiveFinding(
                category: "phishing",
                severity: 0.9,
                title: "\(highRisk.count) High-Risk Phishing Email\(highRisk.count == 1 ? "" : "s") Detected",
                detail: "Subjects: \(highRisk.prefix(3).compactMap { $0.email.headers["Subject"] }.joined(separator: ", "))",
                emailIDs: highRisk.map(\.email.id)
            ))
        }
        if medRisk.count >= 3 {
            findings.append(ProactiveFinding(
                category: "phishing",
                severity: 0.6,
                title: "\(medRisk.count) Suspicious Emails Found",
                detail: "Medium-risk emails from: \(Set(medRisk.prefix(5).compactMap { $0.email.headers["From"] }).joined(separator: ", "))",
                emailIDs: medRisk.map(\.email.id)
            ))
        }

        // 3. PII exposure
        let piiTotal = piiResults.values.reduce(0, +)
        if piiTotal > 0 {
            let types = piiResults.filter { $0.value > 0 }.keys.map(\.rawValue).joined(separator: ", ")
            findings.append(ProactiveFinding(
                category: "pii",
                severity: piiTotal >= 5 ? 0.8 : 0.5,
                title: "\(piiTotal) PII Exposure\(piiTotal == 1 ? "" : "s") Detected",
                detail: "Types found: \(types). Review for sensitive data compliance.",
                emailIDs: []
            ))
        }

        // 4. Sentiment shifts
        let sentiments = EmailNLPEngine.analyzeSentiment(of: Array(emails.prefix(100)))
        if sentiments.count >= 10 {
            let half = sentiments.count / 2
            let firstHalf = sentiments.prefix(half)
            let secondHalf = sentiments.suffix(half)
            let avgFirst = firstHalf.reduce(0.0) { $0 + $1.score } / Double(firstHalf.count)
            let avgSecond = secondHalf.reduce(0.0) { $0 + $1.score } / Double(secondHalf.count)
            let shift = avgSecond - avgFirst
            if abs(shift) > 0.3 {
                let direction = shift > 0 ? "positive" : "negative"
                findings.append(ProactiveFinding(
                    category: "sentiment",
                    severity: min(abs(shift), 1.0),
                    title: "Significant Sentiment Shift Detected",
                    detail: "Overall tone shifted \(direction) by \(String(format: "%.1f", abs(shift) * 100))%. Earlier: \(String(format: "%.2f", avgFirst)), Later: \(String(format: "%.2f", avgSecond))",
                    emailIDs: []
                ))
            }
        }

        // 5. New domain burst (first-time senders with multiple emails)
        var domainFirstSeen: [String: Int] = [:]
        for email in emails {
            guard let from = email.headers["From"],
                  let atIdx = from.lastIndex(of: "@") else { continue }
            let domain = String(from[from.index(after: atIdx)...]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ">")))
            domainFirstSeen[domain, default: 0] += 1
        }
        let burstDomains = domainFirstSeen.filter { $0.value >= 5 }.sorted { $0.value > $1.value }
        if burstDomains.count > 2 {
            findings.append(ProactiveFinding(
                category: "new_domains",
                severity: 0.4,
                title: "\(burstDomains.count) Active External Domains",
                detail: "Top: \(burstDomains.prefix(5).map { "\($0.key)(\($0.value))" }.joined(separator: ", "))",
                emailIDs: []
            ))
        }

        return findings.sorted { $0.severity > $1.severity }
    }

    static func invalidatePrecomputation() {
        fmStateQueue.sync {
            precomputedSenderProfiles = []
            precomputedSecurityScan = nil
            precomputedTopicClusters = []
            precomputedTimeline = []
            precomputationDone = false
            knowledgeGraph = nil
            proactiveFindings = []
        }
    }

    static func getKnowledgeGraph() -> KnowledgeGraph? {
        fmStateQueue.sync { knowledgeGraph }
    }

    // MARK: - 2. Answer Caching with Semantic Similarity

    private struct CachedAnswer {
        let query: String
        let queryVector: [Double]?
        let answer: String
        let intent: QueryIntent
        let emailCount: Int
        let timestamp: Date
    }

    nonisolated(unsafe) private static var answerCache: [CachedAnswer] = []
    private static let maxCacheSize = 20
    private static let cacheHitThreshold: Double = 0.88

    static func invalidateAnswerCache() {
        fmStateQueue.sync { answerCache.removeAll() }
    }

    private static func checkCache(query: String, emailCount: Int) -> String? {
        var cacheCopy = fmStateQueue.sync { answerCache }

        guard !cacheCopy.isEmpty else { return nil }

        cacheCopy.removeAll { $0.emailCount != emailCount }
        let cutoff = Date().addingTimeInterval(-3600)
        cacheCopy.removeAll { $0.timestamp < cutoff }

        fmStateQueue.sync { answerCache = cacheCopy }

        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: query) else {
            return cacheCopy.first { $0.query.lowercased() == query.lowercased() }?.answer
        }

        var bestMatch: (answer: String, similarity: Double)?
        for cached in cacheCopy {
            guard let cachedVector = cached.queryVector else { continue }
            let sim = cosineSim(queryVector, cachedVector)
            if sim > cacheHitThreshold {
                if bestMatch.map({ sim > $0.similarity }) ?? true {
                    bestMatch = (cached.answer, sim)
                }
            }
        }
        return bestMatch?.answer
    }

    private static func cacheAnswer(query: String, answer: String, intent: QueryIntent, emailCount: Int) {
        let vector: [Double]?
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            vector = embedding.vector(for: query)
        } else {
            vector = nil
        }

        let entry = CachedAnswer(
            query: query, queryVector: vector,
            answer: answer, intent: intent,
            emailCount: emailCount, timestamp: Date()
        )
        fmStateQueue.sync {
            answerCache.append(entry)
            if answerCache.count > maxCacheSize {
                answerCache.removeFirst(answerCache.count - maxCacheSize)
            }
        }
    }

    private static func cosineSim(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - 3. Chunk-Level Retrieval (uses existing EmailChunker + EmailSearchIndex)

    private static func chunkLevelRetrieve(
        query: String,
        terms: [String],
        emails: [MBOXParser.RawEmail],
        limit: Int,
        preferredTypes: [ChunkType]? = nil
    ) -> [(email: MBOXParser.RawEmail, bestChunk: String, chunkType: ChunkType)] {
        let chunkResults = EmailSearchIndex.shared.chunkSearch(
            terms: terms, in: emails, maxChunksPerEmail: 1, limit: limit,
            preferredTypes: preferredTypes
        )
        return chunkResults.map { (email: $0.email, bestChunk: $0.chunk, chunkType: $0.chunkType) }
    }

    static let expertChunkPreferences: [ExpertRole: [ChunkType]] = [
        .securityExpert: [.header],
        .sentimentExpert: [.body],
        .entityExpert: [.body, .header],
        .timelineExpert: [.header],
        .topicExpert: [.body]
    ]

    // MARK: - v2.2.4: Anomaly-Aware Expert Enrichment

    nonisolated(unsafe) private static var cachedAnomalies: [AnomalyDetectionEngine.Anomaly]?
    nonisolated(unsafe) private static var cachedAnomalyEmailCount: Int = 0

    private static func getCachedAnomalies(for emails: [MBOXParser.RawEmail]) -> [AnomalyDetectionEngine.Anomaly] {
        fmStateQueue.sync {
            if let cached = cachedAnomalies, cachedAnomalyEmailCount == emails.count {
                return cached
            }
            let anomalies = AnomalyDetectionEngine.detectAnomalies(in: emails)
            cachedAnomalies = anomalies
            cachedAnomalyEmailCount = emails.count
            return anomalies
        }
    }

    static let expertAnomalyPreferences: [ExpertRole: [AnomalyDetectionEngine.AnomalyType]] = [
        .securityExpert: [.newDomain, .recipientAnomaly, .largeAttachment],
        .sentimentExpert: [.toneShift],
        .entityExpert: [.recipientAnomaly, .newDomain],
        .timelineExpert: [.frequencySpike, .unusualHour],
        .topicExpert: [.toneShift, .frequencySpike]
    ]

    private static func anomalyEnrichment(for role: ExpertRole, emails: [MBOXParser.RawEmail]) -> String {
        let anomalies = getCachedAnomalies(for: emails)
        guard let preferredTypes = expertAnomalyPreferences[role] else { return "" }

        let relevant = anomalies.filter { preferredTypes.contains($0.type) && $0.severity >= 0.3 }
        guard !relevant.isEmpty else { return "" }

        var text = "BEHAVIORAL ANOMALIES (auto-detected):\n"
        for anomaly in relevant.prefix(4) {
            text += "  [\(anomaly.type.rawValue)] \(anomaly.title) (severity: \(String(format: "%.0f%%", anomaly.severity * 100)))"
            if !anomaly.detail.isEmpty {
                text += " — \(String(anomaly.detail.prefix(100)))"
            }
            text += "\n"
        }
        return text
    }

    // MARK: - 4. Self-Correction Loop

    @Generable(description: "Validation of an AI-generated answer")
    struct AIAnswerValidation {
        @Guide(description: "How well the answer addresses the question, 1-5")
        var confidence: Int
        @Guide(description: "What specific information is missing from the answer")
        var missingInfo: String
        @Guide(description: "Should we retrieve more data and try again?")
        var needsRetry: Bool
        @Guide(description: "Which expert domain is missing: sentiment, entity, topic, timeline, security, or none")
        var missingExpertDomain: String
    }

    struct ValidationResult {
        let confident: Bool
        let gap: String?
        let missingExpert: ExpertRole?
    }

    static func validateAnswer(
        answer: String,
        query: String,
        intent: QueryIntent
    ) async -> ValidationResult {
        let nlpRating = rateResult(answer: answer, query: query, source: "synthesizer")
        if nlpRating.stars >= 4 { return ValidationResult(confident: true, gap: nil, missingExpert: nil) }

        guard isAvailable else {
            return ValidationResult(confident: nlpRating.stars >= 3, gap: nil, missingExpert: nil)
        }

        do {
            let session = LanguageModelSession(instructions:
                "You are a quality checker. Assess if an answer properly addresses the question. " +
                "Rate confidence 1-5. If missing key info, say exactly what's missing. " +
                "Identify which expert domain is needed: sentiment (emotions/tone), entity (people/organizations), " +
                "topic (themes/subjects), timeline (dates/patterns), security (threats/phishing), or none."
            )
            let prompt = "Question: \(query)\n\nAnswer:\n\(String(answer.prefix(1500)))"
            let response = try await session.respond(to: prompt, generating: AIAnswerValidation.self)
            let validation = response.content

            if validation.confidence >= 4 || !validation.needsRetry {
                return ValidationResult(confident: true, gap: nil, missingExpert: nil)
            }

            let missingExpert = mapDomainToExpert(validation.missingExpertDomain)
            return ValidationResult(confident: false, gap: validation.missingInfo, missingExpert: missingExpert)
        } catch {
            return ValidationResult(confident: nlpRating.stars >= 3, gap: nil, missingExpert: nil)
        }
    }

    private static func mapDomainToExpert(_ domain: String) -> ExpertRole? {
        let lower = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("sentiment") || lower.contains("emotion") || lower.contains("tone") { return .sentimentExpert }
        if lower.contains("entity") || lower.contains("people") || lower.contains("person") || lower.contains("contact") { return .entityExpert }
        if lower.contains("topic") || lower.contains("theme") || lower.contains("subject") || lower.contains("content") { return .topicExpert }
        if lower.contains("timeline") || lower.contains("time") || lower.contains("date") || lower.contains("temporal") { return .timelineExpert }
        if lower.contains("security") || lower.contains("phishing") || lower.contains("threat") || lower.contains("risk") { return .securityExpert }
        return nil
    }

    // MARK: - v2.3.3: Query Reformulation with Synonym Expansion

    private static func expandQueryTerms(_ terms: [String], maxExpansion: Int = 3) -> [String] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return terms }

        var expanded = terms
        for term in terms {
            var neighbors: [String] = []
            embedding.enumerateNeighbors(for: term.lowercased(), maximumCount: maxExpansion) { neighbor, distance in
                if distance < 0.6 && !terms.contains(neighbor) && !expanded.contains(neighbor) {
                    neighbors.append(neighbor)
                }
                return true
            }
            expanded.append(contentsOf: neighbors)
        }

        return Array(Set(expanded))
    }

    // MARK: - 5. NLP-Based Query Decomposition (deterministic, replaces AI planning for reliability)

    private static func decomposeQueryNLP(_ query: String, emails: [MBOXParser.RawEmail]) -> [String] {
        var subQueries: [String] = []

        // Extract person names → entity sub-query
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = query
        var names: [String] = []
        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, range in
            if tag == .personalName || tag == .organizationName {
                names.append(String(query[range]))
            }
            return true
        }
        if !names.isEmpty {
            subQueries.append("Find emails involving \(names.joined(separator: " and "))")
        }

        // Extract time references → temporal sub-query
        let timePatterns = ["last week", "last month", "this week", "this month", "yesterday",
                           "last year", "this year", "recent", "lately", "before", "after",
                           "january", "february", "march", "april", "may", "june",
                           "july", "august", "september", "october", "november", "december",
                           "q1", "q2", "q3", "q4"]
        let qLower = query.lowercased()
        let hasTimeRef = timePatterns.contains { qLower.contains($0) }
        if hasTimeRef {
            subQueries.append("Analyze email volume and patterns over time for: \(query)")
        }

        // Extract comparison signals → comparison sub-query
        let comparisonWords = ["compare", "versus", "vs", "difference", "between", "more than", "less than"]
        if comparisonWords.contains(where: { qLower.contains($0) }) {
            let terms = EmailNLPEngine.extractSearchTerms(from: query)
            if terms.count >= 2 {
                subQueries.append("Analyze '\(terms[0])' emails separately")
                subQueries.append("Analyze '\(terms[1])' emails separately")
            }
        }

        // Extract topic keywords → topic sub-query
        let terms = EmailNLPEngine.extractSearchTerms(from: query)
        let topicTerms = terms.filter { t in !names.map({ $0.lowercased() }).contains(t.lowercased()) }
        if !topicTerms.isEmpty && subQueries.count < 3 {
            subQueries.append("Find and analyze emails about \(topicTerms.joined(separator: ", "))")
        }

        return Array(subQueries.prefix(4))
    }

    // MARK: - 6. Adaptive Session Count

    private static func computeSessionCount(query: String, emails: [MBOXParser.RawEmail], intent: QueryIntent) -> (experts: Int, maxSubQueries: Int) {
        let complexity: Int
        let qLower = query.lowercased()

        // Query complexity score
        var score = 0
        if qLower.count > 80 { score += 1 }
        let questionMarks = qLower.filter { $0 == "?" }.count
        score += min(questionMarks, 2)
        let conjunctions = ["and", "but", "also", "compare", "versus", "both", "between"]
        score += conjunctions.filter { qLower.contains($0) }.count
        if ["who", "what", "when", "where", "why", "how"].filter({ qLower.hasPrefix($0) }).isEmpty {
            score += 1
        }
        complexity = min(score, 5)

        // Scale sessions by archive size + complexity
        let archiveScale: Int
        if emails.count < 500 { archiveScale = 0 }
        else if emails.count < 2000 { archiveScale = 1 }
        else if emails.count < 5000 { archiveScale = 2 }
        else { archiveScale = 3 }

        let totalScale = complexity + archiveScale

        let expertCount: Int
        let maxSubs: Int

        switch totalScale {
        case 0...2:
            expertCount = 1; maxSubs = 1
        case 3...4:
            expertCount = 2; maxSubs = 2
        case 5...6:
            expertCount = 3; maxSubs = 3
        default:
            expertCount = 4; maxSubs = 4
        }

        // Cap experts to what's available for this intent
        let availableExperts = selectExperts(for: intent).count
        return (experts: min(expertCount, availableExperts), maxSubQueries: maxSubs)
    }

    // MARK: - 7. Evidence Chain Tracking (email IDs linked to findings)

    private struct TrackedFinding {
        let finding: AIFinding
        let source: String
        let confidence: Int
        let emailIDs: [UUID]
    }

    private static func trackEvidence(
        finding: AIFinding,
        source: String,
        confidence: Int,
        emails: [MBOXParser.RawEmail]
    ) -> TrackedFinding {
        // Match finding evidence text against known email subjects/senders
        var matchedIDs: [UUID] = []
        let evidenceLower = finding.evidence.lowercased()
        let findingLower = finding.finding.lowercased()

        for email in emails {
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()

            if !subject.isEmpty && (evidenceLower.contains(subject) || findingLower.contains(subject)) {
                matchedIDs.append(email.id)
            } else if !from.isEmpty && from.count > 5 && (evidenceLower.contains(from) || findingLower.contains(from)) {
                matchedIDs.append(email.id)
            }
            if matchedIDs.count >= 5 { break }
        }

        return TrackedFinding(finding: finding, source: source, confidence: confidence, emailIDs: matchedIDs)
    }

    // MARK: - Multi-Session Chain (Plan → Map → Reduce)

    private static let multiSessionThreshold = 50

    private static func planQuery(query: String, profile: String) async -> AIQueryPlan? {
        guard isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions:
                "You are a query planner for an email archive. " +
                "Decide if the question needs multi-step processing. " +
                "Simple questions (find an email, sentiment of one sender) do NOT need multi-step. " +
                "Complex questions (compare, analyze across time, multi-person) DO need multi-step. " +
                "If multi-step, decompose into 2-4 focused sub-queries that each retrieve different data."
            )
            let prompt = "Archive profile:\n\(profile)\n\nQuestion: \(query)"
            let response = try await session.respond(to: prompt, generating: AIQueryPlan.self)
            return response.content
        } catch {
            return nil
        }
    }

    private static func executeSubQuery(
        subQuery: String,
        emails: [MBOXParser.RawEmail],
        profile: String
    ) async -> String {
        let terms = EmailNLPEngine.extractSearchTerms(from: subQuery)
        let (subIntent, _) = semanticClassifyIntent(subQuery)

        var results: [MBOXParser.RawEmail] = []
        if !terms.isEmpty {
            let indexed = EmailSearchIndex.shared.hybridSearch(query: subQuery, terms: terms, limit: 8)
            results = indexed.map(\.email)
        }
        if results.count < 3 {
            let spotlightHits = await SpotlightIndexer.shared.semanticSearch(query: subQuery, limit: 5)
            let spotlightIDs = Set(spotlightHits.compactMap { UUID(uuidString: $0.id) })
            let existingIDs = Set(results.map(\.id))
            for email in emails where spotlightIDs.contains(email.id) && !existingIDs.contains(email.id) {
                results.append(email)
            }
        }
        if results.isEmpty {
            results = Array(emails.prefix(8))
        }

        let nlpStats = gatherTargetedAnalysis(intent: subIntent, relevant: results, all: emails)

        var context = nlpStats.isEmpty ? "" : nlpStats + "\n\n"
        for email in results.prefix(8) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let date = email.headers["Date"] ?? ""
            let body = bodySnippet(for: email, maxLength: 200)
            context += "--- \(subj) ---\nFrom: \(from)\nDate: \(date)\nBody: \(body)\n\n"
        }

        guard isAvailable else { return "Sub-query: \(subQuery)\n\(context)" }

        do {
            let session = LanguageModelSession(instructions:
                "You are analyzing a subset of an email archive. Answer the specific question concisely " +
                "with evidence from the emails. Keep your answer under 200 words. " +
                "Refer to emails by **Subject** and **sender**."
            )
            let prompt = "Question: \(subQuery)\n\n\(context)"
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            return "Sub-query: \(subQuery)\nFound \(results.count) emails. \(context.prefix(500))"
        }
    }

    // MARK: - Multi-Model Router (v4.4.2)

    enum ModelRoute {
        case onDeviceOnly
        case cloudPrimary
        case onDevicePlusCloudVerify
        case hybridParallel
    }

    static func routeModel(
        query: String,
        emailCount: Int,
        intent: QueryIntent
    ) -> ModelRoute {
        #if OFFLINE_MODE
        return .onDeviceOnly
        #else
        let cloudReady: Bool = {
            let enabled = UserDefaults.standard.bool(forKey: "cloudAIEnabled")
            let preferred = UserDefaults.standard.bool(forKey: "cloudAIPreferred")
            return enabled && preferred
        }()

        guard cloudReady else { return .onDeviceOnly }

        let queryLen = query.count
        let isComplex = queryLen > 200 || query.contains(" and ") || query.contains(" then ")
        let isLargeArchive = emailCount > 5000
        let isForensic = UserDefaults.standard.bool(forKey: "forensicModeEnabled")

        let complexIntents: Set<QueryIntent> = [.security, .triage, .entity]
        let isComplexIntent = complexIntents.contains(intent)

        if isForensic && isComplexIntent {
            return .onDevicePlusCloudVerify
        }

        if isComplex && isLargeArchive {
            return .cloudPrimary
        }

        if isComplexIntent || isLargeArchive {
            return .hybridParallel
        }

        return .onDeviceOnly
        #endif
    }

    // v4.4.2: Apply cloud routing to an on-device answer
    private static func applyCloudRouting(
        route: ModelRoute,
        onDeviceAnswer: String,
        query: String,
        intent: QueryIntent,
        emails: [MBOXParser.RawEmail],
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async -> String {
        #if OFFLINE_MODE
        return onDeviceAnswer
        #else
        switch route {
        case .onDeviceOnly:
            return onDeviceAnswer

        case .cloudPrimary:
            do {
                let emailCtx = CloudAIManager.buildEmailContext(from: emails, maxEmails: 15)
                let systemPrompt = "You are an expert email analyst. The on-device AI produced an initial answer. " +
                    "Improve it with deeper analysis. Keep your response concise and well-structured."
                let userMsg = "Question: \(query)\n\nOn-device answer:\n\(onDeviceAnswer)\n\nEmails:\n\(emailCtx)"
                await onUpdate(onDeviceAnswer + "\n\n*Enhancing with cloud AI...*")
                let cloudAnswer = try await CloudAIManager.shared.sendMessage(
                    systemPrompt: systemPrompt, userMessage: userMsg
                )
                let final = cloudAnswer.isEmpty ? onDeviceAnswer : cloudAnswer
                await onUpdate(final)
                return final
            } catch {
                return onDeviceAnswer
            }

        case .onDevicePlusCloudVerify:
            do {
                let emailCtx = CloudAIManager.buildEmailContext(from: emails, maxEmails: 10)
                await onUpdate(onDeviceAnswer + "\n\n*Cloud verification in progress...*")
                let validation = try await CloudAIManager.shared.crossValidate(
                    answer: onDeviceAnswer, query: query, emailContext: emailCtx
                )
                if !validation.isAccurate && validation.confidence >= 3 {
                    var enhanced = onDeviceAnswer
                    if validation.missing != "none" && !validation.missing.isEmpty {
                        enhanced += "\n\n---\n**Additional context** (cloud-verified): \(validation.missing)"
                    }
                    if validation.issues != "none" && !validation.issues.isEmpty {
                        enhanced += "\n\n> ⚠️ Note: \(validation.issues)"
                    }
                    await onUpdate(enhanced)
                    return enhanced
                }
                return onDeviceAnswer
            } catch {
                return onDeviceAnswer
            }

        case .hybridParallel:
            do {
                let emailCtx = CloudAIManager.buildEmailContext(from: emails, maxEmails: 12)
                let systemPrompt = "You are an email analyst providing a parallel perspective. " +
                    "Answer the question based on the emails. Be concise."
                let userMsg = "Question: \(query)\n\nEmails:\n\(emailCtx)"
                await onUpdate(onDeviceAnswer + "\n\n*Running parallel cloud analysis...*")
                let cloudAnswer = try await CloudAIManager.shared.sendMessage(
                    systemPrompt: systemPrompt, userMessage: userMsg
                )
                if !cloudAnswer.isEmpty {
                    let merged = onDeviceAnswer + "\n\n---\n**Cloud AI perspective:** " + cloudAnswer
                    await onUpdate(merged)
                    return merged
                }
                return onDeviceAnswer
            } catch {
                return onDeviceAnswer
            }
        }
        #endif
    }

    // MARK: - respondSmart (unified entry point — all 7 improvements integrated)

    static func respondSmart(
        to query: String,
        emails: [MBOXParser.RawEmail],
        onUpdate: @MainActor @Sendable @escaping (String) -> Void,
        onConfirmAction: (@MainActor @Sendable (String) async -> Bool)? = nil
    ) async throws -> String {
        guard !emails.isEmpty else {
            let msg = "No emails available. Import emails first to use AI analysis."
            await onUpdate(msg)
            return msg
        }

        // ── Improvement 2: Answer Cache Check ──
        if let cached = checkCache(query: query, emailCount: emails.count) {
            await onUpdate(cached)
            return cached
        }

        // ── Dual Classification: NLEmbedding + Apple AI with consensus ──
        let parsed = understandQuery(query, emails: emails)
        let classification = await classifyIntentDual(query)
        let intent = classification.intent
        let searchTerms = EmailNLPEngine.extractSearchTerms(from: query)
        let profile = archiveProfile(emails: emails)
        let effectiveQuery = parsed.rewrittenPrompt

        // ── Improvement 6: Adaptive Session Count ──
        let sessionConfig = computeSessionCount(query: query, emails: emails, intent: intent)

        // ── v4.4.2: Multi-Model Routing ──
        let modelRoute = routeModel(query: query, emailCount: emails.count, intent: intent)

        // ── v3.3.1: Agentic Planner for sequential multi-step queries ──
        if AgenticPlanner.isAgenticQuery(query) {
            if let agenticPlan = await AgenticPlanner.generatePlan(query: query, emails: emails, profile: profile) {
                let answer = try await AgenticPlanner.executePlan(
                    plan: agenticPlan, query: effectiveQuery, emails: emails,
                    profile: profile, onUpdate: onUpdate,
                    onConfirmAction: onConfirmAction
                )
                cacheAnswer(query: query, answer: answer, intent: intent, emailCount: emails.count)
                recordTurn(query: query, intent: intent, answer: answer)
                return answer
            }
        }

        // For large archives, try multi-session chain for complex queries
        if emails.count >= multiSessionThreshold {
            let nlpSubQueries = decomposeQueryNLP(query, emails: emails)
            let plan: AIQueryPlan?

            if nlpSubQueries.count >= 2 {
                let capped = Array(nlpSubQueries.prefix(sessionConfig.maxSubQueries))
                plan = AIQueryPlan(needsMultiStep: true, subQueries: capped, synthesisGoal: "Answer: \(query)")
            } else {
                plan = await planQuery(query: query, profile: profile)
            }

            if let plan, plan.needsMultiStep, !plan.subQueries.isEmpty {
                let answer = try await respondMultiSession(
                    query: effectiveQuery, plan: plan, intent: intent,
                    classification: classification, emails: emails, profile: profile, onUpdate: onUpdate
                )

                // ── Improvement 4: Self-Correction with Expert Re-Routing (v2.1.4) ──
                let validation = await validateAnswer(answer: answer, query: query, intent: intent)
                if !validation.confident, let gap = validation.gap, !gap.isEmpty {
                    let truncatedGap = String(gap.prefix(200))

                    if let missingExpert = validation.missingExpert {
                        // Re-route to the specific missing expert — targeted fix
                        await onUpdate(answer + "\n\n*Supplementing with \(missingExpert.rawValue) analysis...*")
                        let supplementFindings = await runExpertStructured(
                            role: missingExpert, query: "\(query) — gap: \(truncatedGap)", emails: emails
                        )
                        let supplementText = supplementFindings.findings
                            .filter { $0.relevance == .high || $0.relevance == .medium }
                            .map { $0.finding }
                            .joined(separator: "\n")
                        if !supplementText.isEmpty {
                            let corrected = answer + "\n\n---\n**Additional \(missingExpert.rawValue) analysis:** " + supplementText
                            await onUpdate(corrected)
                            cacheAnswer(query: query, answer: corrected, intent: intent, emailCount: emails.count)
                            recordTurn(query: query, intent: intent, answer: corrected)
                            return corrected
                        }
                    }

                    // v2.3.3: Query Reformulation — expand search terms with NLEmbedding synonyms
                    let originalTerms = EmailNLPEngine.extractSearchTerms(from: query)
                    let expandedTerms = expandQueryTerms(originalTerms)
                    let retryTerms = expandedTerms.isEmpty
                        ? EmailNLPEngine.extractSearchTerms(from: truncatedGap)
                        : expandedTerms
                    if !retryTerms.isEmpty {
                        let reformulatedQuery = retryTerms.count > originalTerms.count
                            ? "\(query) (also considering: \(retryTerms.filter { !originalTerms.contains($0) }.joined(separator: ", ")))"
                            : "\(query) — specifically: \(truncatedGap)"
                        let supplement = try await respondSingleSession(
                            query: reformulatedQuery,
                            intent: intent, searchTerms: retryTerms,
                            emails: emails, profile: profile, onUpdate: { _ in }
                        )
                        let corrected = answer + "\n\n---\n**Additional detail:** " + supplement
                        await onUpdate(corrected)
                        cacheAnswer(query: query, answer: corrected, intent: intent, emailCount: emails.count)
                        recordTurn(query: query, intent: intent, answer: corrected)
                        return corrected
                    }
                }

                // ── v4.4.2: Apply cloud routing to multi-session answer ──
                let routed = await applyCloudRouting(
                    route: modelRoute, onDeviceAnswer: answer, query: query,
                    intent: intent, emails: emails, onUpdate: onUpdate
                )
                cacheAnswer(query: query, answer: routed, intent: intent, emailCount: emails.count)
                return routed
            }
        }

        // Single-session path (small archives or simple queries)
        let answer = try await respondSingleSession(
            query: effectiveQuery, intent: intent, searchTerms: searchTerms,
            emails: emails, profile: profile, onUpdate: onUpdate
        )

        // ── v4.4.2: Apply cloud routing to single-session answer ──
        let routed = await applyCloudRouting(
            route: modelRoute, onDeviceAnswer: answer, query: query,
            intent: intent, emails: emails, onUpdate: onUpdate
        )
        cacheAnswer(query: query, answer: routed, intent: intent, emailCount: emails.count)
        return routed
    }

    // MARK: - Multi-Session Chain (Plan → Map → Reduce → Stream)

    // MARK: - Parallel Expert Sessions

    enum ExpertRole: String, CaseIterable {
        case sentimentExpert
        case entityExpert
        case topicExpert
        case timelineExpert
        case securityExpert

        var correspondingIntent: QueryIntent {
            switch self {
            case .sentimentExpert: return .sentiment
            case .entityExpert: return .entity
            case .topicExpert: return .topicAnalysis
            case .timelineExpert: return .temporal
            case .securityExpert: return .security
            }
        }
    }

    private static func selectExperts(for intent: QueryIntent) -> [ExpertRole] {
        switch intent {
        case .sentiment: return [.sentimentExpert, .entityExpert]
        case .entity: return [.entityExpert, .sentimentExpert, .topicExpert]
        case .security: return [.securityExpert, .entityExpert]
        case .triage: return [.sentimentExpert, .timelineExpert]
        case .topicAnalysis: return [.topicExpert, .entityExpert]
        case .temporal: return [.timelineExpert, .sentimentExpert, .topicExpert]
        case .summary: return [.sentimentExpert, .topicExpert, .entityExpert, .timelineExpert]
        case .general: return [.sentimentExpert, .topicExpert, .entityExpert]
        case .search, .thread: return [.entityExpert]
        case .statistics: return [.sentimentExpert, .topicExpert, .entityExpert]
        }
    }

    // MARK: - Cross-Email Threading Context (v2.1.3)

    private static func buildThreadContext(for emails: [MBOXParser.RawEmail], query: String, maxChars: Int) -> String {
        let threads = ThreadGrouper.group(emails).filter { $0.count > 1 }
        guard !threads.isEmpty else { return "" }

        let queryTerms = Set(EmailNLPEngine.extractSearchTerms(from: query).map { $0.lowercased() })

        let rankedThreads = threads.sorted { a, b in
            let aRelevance = queryTerms.isEmpty ? 0 : a.allEmails.reduce(0) { acc, email in
                let text = (email.headers["Subject"] ?? "") + " " + email.plainBody
                return acc + queryTerms.filter { text.lowercased().contains($0) }.count
            }
            let bRelevance = queryTerms.isEmpty ? 0 : b.allEmails.reduce(0) { acc, email in
                let text = (email.headers["Subject"] ?? "") + " " + email.plainBody
                return acc + queryTerms.filter { text.lowercased().contains($0) }.count
            }
            if aRelevance != bRelevance { return aRelevance > bRelevance }
            return a.count > b.count
        }

        var result = "THREAD CONTEXT (reply chains):\n"
        var charCount = result.count

        for thread in rankedThreads.prefix(3) {
            let participants = Set(thread.allEmails.compactMap { $0.headers["From"] })
            var threadSection = "── Thread: \"\(thread.subject)\" (\(thread.count) msgs, \(participants.count) participants) ──\n"
            threadSection += "Participants: \(participants.prefix(5).joined(separator: ", "))\n"

            for (i, email) in thread.allEmails.enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
                let date = email.headers["Date"] ?? "?"
                let sentiment = EmailNLPEngine.analyzeSentiment(of: [email]).first
                let sentimentLabel = sentiment.map { $0.score > 0.2 ? "+" : $0.score < -0.2 ? "-" : "~" } ?? "~"
                let body = bodySnippet(for: email, maxLength: 120)
                threadSection += "  [\(i+1)] \(from) (\(date)) [\(sentimentLabel)]: \(body)\n"
            }
            threadSection += "\n"

            if charCount + threadSection.count > maxChars { break }
            result += threadSection
            charCount += threadSection.count
        }

        return result
    }

    private static func runExpertStructured(
        role: ExpertRole,
        query: String,
        emails: [MBOXParser.RawEmail]
    ) async -> AISessionFindings {
        let nlpData: String
        let expertType: String

        switch role {
        case .sentimentExpert:
            let s = EmailNLPEngine.averageSentiment(of: emails)
            let perEmail = EmailNLPEngine.analyzeSentiment(of: emails)
            let contacts = EmailNLPEngine.contactInsights(from: emails, limit: 5)

            var d = "SENTIMENT OVERVIEW: \(s.label) (avg \(String(format: "%.2f", s.average))). +\(s.positive)/~\(s.neutral)/-\(s.negative).\n"

            // Per-contact sentiment
            if !contacts.isEmpty {
                d += "PER-CONTACT: " + contacts.prefix(5).map { "\($0.address): \($0.sentimentLabel) (\($0.emailCount) emails)" }.joined(separator: "; ") + "\n"
            }

            // Most positive and most negative emails by subject
            let sorted = perEmail.sorted { $0.score > $1.score }
            let topPositive = sorted.prefix(3)
            let topNegative = sorted.suffix(3).reversed()
            if !topPositive.isEmpty {
                d += "MOST POSITIVE: " + topPositive.map { "\($0.email.headers["Subject"] ?? "?"): \(String(format: "%.2f", $0.score))" }.joined(separator: "; ") + "\n"
            }
            if let neg = topNegative.first, neg.score < -0.3 {
                d += "MOST NEGATIVE: " + Array(topNegative).filter { $0.score < -0.3 }.map { "\($0.email.headers["Subject"] ?? "?"): \(String(format: "%.2f", $0.score))" }.joined(separator: "; ") + "\n"
            }

            // Thread sentiment trends
            let threads = ThreadGrouper.group(emails).filter { $0.count > 1 }
            if !threads.isEmpty {
                let trendData = threads.prefix(3).map { thread -> String in
                    let trend = EmailNLPEngine.threadSentimentTrend(thread.allEmails)
                    return "\"\(thread.subject)\": \(trend.overallTrend)"
                }
                d += "THREAD TRENDS: " + trendData.joined(separator: "; ") + "\n"
            }

            // Sentiment by topic correlation
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 5)
            if !topics.isEmpty {
                d += "TOPICS: " + topics.map { $0.word }.joined(separator: ", ") + "\n"
            }

            nlpData = d
            expertType = "sentiment and emotional intelligence"

        case .entityExpert:
            let entities = EmailNLPEngine.extractEntities(from: emails, limit: 10)
            let contacts = EmailNLPEngine.contactInsights(from: emails, limit: 8)

            var d = ""
            if !entities.isEmpty {
                d += "ENTITIES: " + entities.map { "\($0.name) (\($0.type), \($0.count)x)" }.joined(separator: "; ") + "\n"
            }

            // Contact communication patterns
            if !contacts.isEmpty {
                d += "CONTACTS:\n"
                for c in contacts.prefix(6) {
                    d += "  \(c.address): \(c.emailCount) emails, sentiment: \(c.sentimentLabel)"
                    d += "\n"
                }
            }

            // Sender domain distribution
            var domains: [String: Int] = [:]
            for email in emails {
                if let from = email.headers["From"], let atIdx = from.lastIndex(of: "@") {
                    let afterAt = from[from.index(after: atIdx)...]
                    let domain = String(afterAt.prefix(while: { $0 != ">" && $0 != " " && $0 != "," })).lowercased()
                    if !domain.isEmpty { domains[domain, default: 0] += 1 }
                }
            }
            let topDomains = domains.sorted { $0.value > $1.value }.prefix(5)
            if !topDomains.isEmpty {
                d += "DOMAINS: " + topDomains.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "\n"
            }

            // Sent vs received
            let sent = emails.filter { $0.messageType == "sent" }.count
            let recv = emails.filter { $0.messageType == "received" }.count
            d += "DIRECTION: \(sent) sent, \(recv) received\n"

            nlpData = d
            expertType = "people and relationship analysis"

        case .topicExpert:
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 12)
            let cls = EmailNLPEngine.classifyAll(emails)

            var d = ""
            if !topics.isEmpty {
                d += "TOPICS: " + topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: ", ") + "\n"
            }

            // Category distribution
            let catStrs = EmailNLPEngine.EmailCategory.allCases.compactMap { c -> String? in
                guard let n = cls[c], n > 0 else { return nil }; return "\(c.rawValue): \(n)"
            }
            if !catStrs.isEmpty { d += "CATEGORIES: " + catStrs.joined(separator: ", ") + "\n" }

            // Topic by sender (which senders discuss which topics)
            var senderTopics: [String: [String]] = [:]
            for email in emails.prefix(100) {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let emailTopics = EmailNLPEngine.extractTopics(from: [email], limit: 2)
                for t in emailTopics {
                    senderTopics[from, default: []].append(t.word)
                }
            }
            let topSenderTopics = senderTopics.sorted { $0.value.count > $1.value.count }.prefix(4)
            if !topSenderTopics.isEmpty {
                d += "SENDER-TOPIC MAP: " + topSenderTopics.map { "\($0.key): \(Array(Set($0.value)).prefix(3).joined(separator: ", "))" }.joined(separator: "; ") + "\n"
            }

            // Thread topics (what threads discuss)
            let threads = ThreadGrouper.group(emails).filter { $0.count > 1 }
            if !threads.isEmpty {
                d += "THREAD TOPICS: " + threads.prefix(4).map { "\"\($0.subject)\" (\($0.count) msgs)" }.joined(separator: "; ") + "\n"
            }

            nlpData = d
            expertType = "content and topic analysis"

        case .timelineExpert:
            let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            let f = DateFormatter(); f.dateStyle = .medium
            let cal = Calendar.current

            var d = "TIMELINE: \(emails.count) emails"
            if let first = dates.first, let last = dates.last {
                d += " from \(f.string(from: first)) to \(f.string(from: last))\n"
            } else {
                d += "\n"
            }

            // Weekly volume
            if dates.count >= 7 {
                var weekCounts: [String: Int] = [:]
                for date in dates {
                    let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                    let key = "\(components.yearForWeekOfYear ?? 0)-W\(components.weekOfYear ?? 0)"
                    weekCounts[key, default: 0] += 1
                }
                let sortedWeeks = weekCounts.sorted { $0.key < $1.key }
                d += "WEEKLY: " + sortedWeeks.suffix(8).map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "\n"

                // Peak and quietest weeks
                if let peak = sortedWeeks.max(by: { $0.value < $1.value }) {
                    d += "PEAK WEEK: \(peak.key) (\(peak.value) emails)\n"
                }
                if let quiet = sortedWeeks.min(by: { $0.value < $1.value }) {
                    d += "QUIETEST WEEK: \(quiet.key) (\(quiet.value) emails)\n"
                }
            }

            // Day-of-week distribution
            var dayOfWeek: [Int: Int] = [:]
            for date in dates {
                let weekday = cal.component(.weekday, from: date)
                dayOfWeek[weekday, default: 0] += 1
            }
            let dayNames = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
            let dayStr = (1...7).compactMap { day -> String? in
                guard let count = dayOfWeek[day], count > 0 else { return nil }
                return "\(dayNames[day] ?? "?"): \(count)"
            }
            if !dayStr.isEmpty { d += "BY DAY: " + dayStr.joined(separator: ", ") + "\n" }

            // Hour distribution (business vs off-hours)
            var hourBuckets = [String: Int]()
            for date in dates {
                let h = cal.component(.hour, from: date)
                let bucket: String
                switch h {
                case 6..<9: bucket = "early-morning"
                case 9..<12: bucket = "morning"
                case 12..<14: bucket = "midday"
                case 14..<17: bucket = "afternoon"
                case 17..<20: bucket = "evening"
                default: bucket = "night"
                }
                hourBuckets[bucket, default: 0] += 1
            }
            d += "BY TIME: " + hourBuckets.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "\n"

            // Anomalies from cached detection (v2.2.4)
            let timeAnomalies = getCachedAnomalies(for: emails).filter { $0.type == .frequencySpike || $0.type == .unusualHour }
            if !timeAnomalies.isEmpty {
                d += "ANOMALIES: " + timeAnomalies.prefix(3).map { "\($0.title) (severity: \(String(format: "%.0f%%", $0.severity * 100)))" }.joined(separator: "; ") + "\n"
            }

            // Sent vs received over time (rough ratio)
            let sent = emails.filter { $0.messageType == "sent" }.count
            let recv = emails.filter { $0.messageType == "received" }.count
            d += "DIRECTION: \(sent) sent, \(recv) received\n"

            nlpData = d
            expertType = "temporal pattern analysis"

        case .securityExpert:
            let flags = EmailNLPEngine.detectPhishing(in: emails)
            let piiFindings = EmailNLPEngine.detectPII(in: emails)
            let piiSummary = EmailNLPEngine.piiSummary(in: emails)

            var d = "SECURITY SCAN: \(flags.count) phishing flags in \(emails.count) emails.\n"

            // Detailed phishing risks
            if !flags.isEmpty {
                d += "PHISHING RISKS:\n"
                for flag in flags.prefix(5) {
                    let subj = flag.email.headers["Subject"] ?? "?"
                    let from = flag.email.headers["From"] ?? "?"
                    d += "  [\(flag.riskLevel.rawValue.uppercased())] \"\(subj)\" from \(from)"
                    if !flag.reasons.isEmpty {
                        d += " — \(flag.reasons.prefix(2).joined(separator: ", "))"
                    }
                    d += "\n"
                }
            }

            // PII findings with contextual risk (v2.2.2)
            if !piiSummary.isEmpty {
                d += "PII EXPOSURE: " + piiSummary.map { "\($0.key.rawValue): \($0.value) instance(s)" }.joined(separator: ", ") + "\n"
            }
            if !piiFindings.isEmpty {
                let highRiskPII = piiFindings.filter { $0.contextualRiskScore >= 5.0 }
                let medRiskPII = piiFindings.filter { $0.contextualRiskScore >= 2.0 && $0.contextualRiskScore < 5.0 }
                if !highRiskPII.isEmpty {
                    d += "HIGH-RISK PII: " + highRiskPII.prefix(3).map {
                        "\($0.type.rawValue) in \($0.riskContext.rawValue) of \"\($0.emailSubject)\" (risk: \(String(format: "%.1f", $0.contextualRiskScore)))"
                    }.joined(separator: "; ") + "\n"
                }
                if !medRiskPII.isEmpty {
                    d += "MODERATE PII: " + medRiskPII.prefix(3).map {
                        "\($0.type.rawValue) in \($0.riskContext.rawValue) of \"\($0.emailSubject)\""
                    }.joined(separator: "; ") + "\n"
                }
            }

            // Anomalies from cached detection (v2.2.4)
            let securityAnomalies = getCachedAnomalies(for: emails).filter { $0.type == .newDomain || $0.type == .recipientAnomaly || $0.type == .largeAttachment }
            if !securityAnomalies.isEmpty {
                d += "BEHAVIORAL ANOMALIES:\n"
                for a in securityAnomalies.prefix(4) {
                    d += "  [\(a.type.rawValue)] \(a.title) (severity: \(String(format: "%.0f%%", a.severity * 100)))\n"
                }
            }

            // Domain analysis
            var domains: [String: Int] = [:]
            for email in emails {
                if let from = email.headers["From"], let atIdx = from.lastIndex(of: "@") {
                    let afterAt = from[from.index(after: atIdx)...]
                    let domain = String(afterAt.prefix(while: { $0 != ">" && $0 != " " && $0 != "," })).lowercased()
                    if !domain.isEmpty { domains[domain, default: 0] += 1 }
                }
            }
            let rareDomains = domains.filter { $0.value == 1 }
            if !rareDomains.isEmpty {
                d += "ONE-TIME DOMAINS (\(rareDomains.count)): " + rareDomains.keys.sorted().prefix(5).joined(separator: ", ") + "\n"
            }

            // v2.2.1: Enhanced authentication analysis
            var authFailCount = 0
            var authPassCount = 0
            for email in emails.prefix(50) {
                let auth = EmailNLPEngine.parseAuthenticationResults(email.headers)
                if auth.failureCount > 0 { authFailCount += 1 }
                if auth.isFullyAuthenticated { authPassCount += 1 }
            }
            let authChecked = min(emails.count, 50)
            if authChecked > 0 {
                d += "AUTH STATUS: \(authPassCount)/\(authChecked) fully authenticated, \(authFailCount) with failures\n"
            }

            nlpData = d
            expertType = "cybersecurity and data protection"
        }

        let expertInstructions: String
        switch role {
        case .sentimentExpert:
            expertInstructions = """
                Sentiment analyst. Find: tone shifts in threads, passive-aggressive language, \
                relationship health (warming/cooling), emotional anomalies. \
                Format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .entityExpert:
            expertInstructions = """
                Network analyst. Find: decision-makers, key contacts by influence, \
                team boundaries, role changes, domain affiliations. \
                Format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .topicExpert:
            expertInstructions = """
                Topic analyst. Find: main themes, topic lifecycle, decision points, \
                urgency signals, unresolved questions, topic ownership. \
                Format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .timelineExpert:
            expertInstructions = """
                Timeline analyst. Find: communication rhythms, volume spikes, \
                response latency, out-of-pattern behavior, cadence changes. \
                Format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .securityExpert:
            expertInstructions = """
                Security analyst. Find: phishing indicators, PII exposure, \
                suspicious senders, data exfiltration, social engineering. \
                Format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        }

        // Retrieve domain-specific chunks with intent-aware budget
        let queryTerms = EmailNLPEngine.extractSearchTerms(from: query)
        let preferredTypes = expertChunkPreferences[role]
        let expertBudget = contextBudget(for: role.correspondingIntent)
        let nlpDataBudget = expertBudget.findingsChars
        var enrichedData = String(nlpData.prefix(nlpDataBudget))
        if !queryTerms.isEmpty {
            let ragSlotBudget = expertBudget.ragChars
            let domainChunks = chunkLevelRetrieve(
                query: query, terms: queryTerms, emails: emails, limit: 3,
                preferredTypes: preferredTypes
            )
            if !domainChunks.isEmpty {
                var ragText = "\nRELEVANT \(preferredTypes?.first?.rawValue.uppercased() ?? "CONTENT") PASSAGES:\n"
                for dc in domainChunks {
                    let subj = dc.email.headers["Subject"] ?? "?"
                    let from = dc.email.headers["From"] ?? "?"
                    ragText += "[\(dc.chunkType.rawValue)] \(subj) (from \(from)): \(String(dc.bestChunk.prefix(300)))\n"
                }
                enrichedData += String(ragText.prefix(ragSlotBudget))
            }
        }

        // Cross-email threading context — reply chain awareness (v2.1.3)
        let threadBudget = expertBudget.headerChars / 2
        let threadCtx = buildThreadContext(for: emails, query: query, maxChars: threadBudget)
        if !threadCtx.isEmpty {
            enrichedData += "\n" + threadCtx
        }

        // Anomaly-aware enrichment — feed relevant anomalies into expert (v2.2.4)
        let anomalyText = anomalyEnrichment(for: role, emails: emails)
        if !anomalyText.isEmpty {
            enrichedData += "\n" + anomalyText
        }

        // v3.7.1: Predictive enrichment for triage-relevant experts
        if role == .sentimentExpert || role == .timelineExpert {
            let predictiveText = PredictiveEngine.summaryForAI(emails: emails)
            if !predictiveText.isEmpty {
                enrichedData += "\n" + String(predictiveText.prefix(600))
            }
        }

        // v3.1.3: Knowledge graph enrichment for entity and topic experts
        if let graph = getKnowledgeGraph(), graph.nodeCount > 0 {
            let kgText: String
            switch role {
            case .entityExpert:
                kgText = graph.summaryForAI(focus: query, limit: 10)
            case .topicExpert:
                let topTopics = graph.topNodes(by: .topic, limit: 5)
                var text = "TOPIC-PERSON MAP:\n"
                for topic in topTopics {
                    let people = graph.neighbors(of: topic.id, type: .discussesTopic)
                        .filter { $0.type == .person }
                        .sorted { $0.weight > $1.weight }
                        .prefix(3)
                    if !people.isEmpty {
                        text += "  \(topic.label): \(people.map(\.label).joined(separator: ", "))\n"
                    }
                }
                kgText = text
            case .securityExpert:
                let oneTimeDomains = graph.findNodes(type: .domain).filter { $0.weight <= 1 }
                if !oneTimeDomains.isEmpty {
                    kgText = "KG ONE-TIME DOMAINS: \(oneTimeDomains.prefix(5).map(\.label).joined(separator: ", "))\n"
                } else {
                    kgText = ""
                }
            default:
                kgText = ""
            }
            if !kgText.isEmpty {
                enrichedData += "\n" + String(kgText.prefix(500))
            }
        }

        guard isAvailable else {
            return AISessionFindings(
                findings: [AIFinding(finding: enrichedData, evidence: "", relevance: .medium)],
                summary: "\(expertType): \(enrichedData.prefix(100))",
                confidence: 3
            )
        }

        do {
            let session = LanguageModelSession(instructions:
                expertInstructions + " " +
                "Analyze the data and produce structured findings. " +
                "Each finding must be one specific, evidence-backed sentence. " +
                "Rate relevance: high = directly answers the question, medium = useful context, low = tangential."
            )
            let response = try await session.respond(
                to: "Question: \(query)\n\nData:\n\(enrichedData)",
                generating: AISessionFindings.self
            )
            return response.content
        } catch {
            return AISessionFindings(
                findings: [AIFinding(finding: enrichedData, evidence: "", relevance: .medium)],
                summary: "\(expertType): \(enrichedData.prefix(100))",
                confidence: 2
            )
        }
    }

    // MARK: - Result Relevance Scoring (deterministic, no AI cost)

    private struct RatedResult {
        let source: String
        let content: String
        let score: Double      // 0.0 – 1.0
        let stars: Int         // 1 – 5
        let label: String      // "★★★★★ HIGHLY RELEVANT" etc.
        let evidence: Int      // count of concrete references found
    }

    private static func rateResult(answer: String, query: String, source: String) -> RatedResult {
        let queryLower = query.lowercased()
        let answerLower = answer.lowercased()

        // 1. Query term coverage (0–0.35): what fraction of query keywords appear in the answer
        let queryWords = queryLower
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 }
        let stopWords: Set<String> = ["the", "and", "for", "are", "but", "not", "you", "all",
                                       "can", "had", "her", "was", "one", "our", "out", "has",
                                       "what", "how", "who", "when", "where", "which", "their",
                                       "about", "from", "this", "that", "with", "have", "does",
                                       "many", "much", "emails", "email", "show", "tell", "give"]
        let meaningfulWords = queryWords.filter { !stopWords.contains($0) }
        let coverage: Double
        if meaningfulWords.isEmpty {
            coverage = 0.2
        } else {
            let matched = meaningfulWords.filter { answerLower.contains($0) }.count
            coverage = Double(matched) / Double(meaningfulWords.count)
        }
        let coverageScore = min(0.35, coverage * 0.35)

        // 2. Evidence density (0–0.30): concrete references = email subjects, names, dates, numbers
        var evidenceCount = 0
        let subjectPattern = try? NSRegularExpression(pattern: "\\*\\*[^*]+\\*\\*", options: [])
        evidenceCount += subjectPattern?.numberOfMatches(
            in: answer, range: NSRange(answer.startIndex..., in: answer)
        ) ?? 0
        let datePattern = try? NSRegularExpression(pattern: "\\b\\d{1,2}[/-]\\d{1,2}[/-]\\d{2,4}\\b|\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\w*\\s+\\d{1,2}", options: .caseInsensitive)
        evidenceCount += datePattern?.numberOfMatches(
            in: answer, range: NSRange(answer.startIndex..., in: answer)
        ) ?? 0
        let numberPattern = try? NSRegularExpression(pattern: "\\b\\d+\\.?\\d*%|\\b\\d{2,}\\b", options: [])
        evidenceCount += numberPattern?.numberOfMatches(
            in: answer, range: NSRange(answer.startIndex..., in: answer)
        ) ?? 0
        let densityScore = min(0.30, Double(evidenceCount) * 0.03)

        // 3. Specificity (0–0.20): not vague — penalize very short or very generic answers
        let wordCount = answer.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let specificityScore: Double
        if wordCount < 10 {
            specificityScore = 0.02
        } else if wordCount < 30 {
            specificityScore = 0.08
        } else if wordCount < 80 {
            specificityScore = 0.15
        } else {
            specificityScore = 0.20
        }

        // 4. Novelty signal (0–0.15): does it mention things NOT in the query? (new info)
        let answerOnlyWords = answerLower
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) && !queryLower.contains($0) }
        let uniqueNovel = Set(answerOnlyWords).count
        let noveltyScore = min(0.15, Double(uniqueNovel) * 0.005)

        let totalScore = coverageScore + densityScore + specificityScore + noveltyScore
        let clamped = min(1.0, max(0.0, totalScore))
        let stars = max(1, min(5, Int(ceil(clamped * 5.0))))

        let label: String
        switch stars {
        case 5: label = "★★★★★ HIGHLY RELEVANT"
        case 4: label = "★★★★ RELEVANT"
        case 3: label = "★★★ MODERATE"
        case 2: label = "★★ LOW RELEVANCE"
        default: label = "★ MINIMAL"
        }

        return RatedResult(
            source: source,
            content: answer,
            score: clamped,
            stars: stars,
            label: label,
            evidence: evidenceCount
        )
    }

    // MARK: - respondMultiSession (Dynamic Fan-In with Structured Findings)

    private static func respondMultiSession(
        query: String,
        plan: AIQueryPlan,
        intent: QueryIntent,
        classification: IntentClassification? = nil,
        emails: [MBOXParser.RawEmail],
        profile: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // ── Semantic expert selection — ambiguous queries activate more experts ──
        let sessionConfig = computeSessionCount(query: query, emails: emails, intent: intent)
        let allExperts = semanticSelectExperts(query, intent: intent)
        let maxExperts: Int
        if classification?.isAmbiguous == true {
            maxExperts = min(allExperts.count, sessionConfig.experts + 1)
        } else {
            maxExperts = sessionConfig.experts
        }
        let experts = Array(allExperts.prefix(maxExperts))
        // v3.5.1: Include matching custom experts
        let customExperts = matchingCustomExperts(for: query, maxCount: 2)
        let totalParallel = plan.subQueries.count + experts.count + customExperts.count
        // v2.3.2: Progressive streaming with expert progress indicator
        let expertNames = experts.map { $0.rawValue.replacingOccurrences(of: "Expert", with: "") }
            + customExperts.map(\.name)
        var progressStatus = experts.map { "[ ] \($0.rawValue.replacingOccurrences(of: "Expert", with: ""))" }
            + customExperts.map { "[ ] \($0.name)" }
        let progressLine = progressStatus.joined(separator: " ")
        await onUpdate("*Layer 1: Deploying \(totalParallel) parallel AI sessions across \(emails.count) emails...*\n\(progressLine)\n\n")

        // ── Layer 1: Parallel structured extraction with progressive updates ──
        var expertFindings: [(ExpertRole, AISessionFindings)] = []
        var customExpertFindings: [(String, AISessionFindings)] = []
        var subFindings: [(String, AISessionFindings)] = []
        var completedExperts = 0
        var partialUpdates: [String] = []

        await withTaskGroup(of: (String, Int?, ExpertRole?, String?, AISessionFindings).self) { group in
            for expert in experts {
                group.addTask {
                    let findings = await runExpertStructured(role: expert, query: query, emails: emails)
                    return ("expert", nil, expert, nil, findings)
                }
            }
            // v3.5.1: Custom expert parallel tasks
            for customExpert in customExperts {
                let captured = customExpert
                group.addTask {
                    let findings = await runCustomExpertStructured(expert: captured, query: query, emails: emails)
                    return ("custom", nil, nil, captured.name, findings)
                }
            }
            for (i, subQ) in plan.subQueries.enumerated() {
                let capturedSubQ = subQ
                group.addTask {
                    let findings = await executeSubQueryStructured(subQuery: capturedSubQ, emails: emails, profile: profile)
                    return ("map", i, nil, nil, findings)
                }
            }

            var mapIndexed: [(Int, String, AISessionFindings)] = []
            for await (type, idx, role, customName, findings) in group {
                if type == "expert", let r = role {
                    expertFindings.append((r, findings))
                    completedExperts += 1

                    if let expertIdx = experts.firstIndex(of: r) {
                        progressStatus[expertIdx] = "[x] \(expertNames[expertIdx])"
                    }

                    if let topFinding = findings.findings.first(where: { $0.relevance == .high }) ?? findings.findings.first {
                        partialUpdates.append("**\(r.rawValue)**: \(String(topFinding.finding.prefix(120)))")
                    }

                    let updatedProgress = progressStatus.joined(separator: " ")
                    let partialText = partialUpdates.joined(separator: "\n")
                    await onUpdate("*Layer 1: \(completedExperts)/\(totalParallel) complete*\n\(updatedProgress)\n\n\(partialText)\n\n")

                } else if type == "custom", let name = customName {
                    customExpertFindings.append((name, findings))
                    completedExperts += 1

                    let customIdx = experts.count + (customExperts.firstIndex(where: { $0.name == name }) ?? 0)
                    progressStatus[customIdx] = "[x] \(name)"

                    if let topFinding = findings.findings.first(where: { $0.relevance == .high }) ?? findings.findings.first {
                        partialUpdates.append("**\(name)**: \(String(topFinding.finding.prefix(120)))")
                    }

                    let updatedProgress = progressStatus.joined(separator: " ")
                    let partialText = partialUpdates.joined(separator: "\n")
                    await onUpdate("*Layer 1: \(completedExperts)/\(totalParallel) complete*\n\(updatedProgress)\n\n\(partialText)\n\n")

                } else if type == "map", let i = idx, i < plan.subQueries.count {
                    mapIndexed.append((i, plan.subQueries[i], findings))
                }
            }
            subFindings = mapIndexed.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }

        // ── Collect all findings + track evidence chains (Improvement 7) ──
        var allFindings: [(source: String, finding: AIFinding, confidence: Int)] = []
        var trackedFindings: [TrackedFinding] = []

        for (role, sessionF) in expertFindings {
            for finding in sessionF.findings {
                allFindings.append((source: role.rawValue, finding: finding, confidence: sessionF.confidence))
                trackedFindings.append(trackEvidence(finding: finding, source: role.rawValue, confidence: sessionF.confidence, emails: emails))
            }
        }
        // v3.5.1: Custom expert findings
        for (name, sessionF) in customExpertFindings {
            for finding in sessionF.findings {
                allFindings.append((source: "custom:\(name)", finding: finding, confidence: sessionF.confidence))
                trackedFindings.append(trackEvidence(finding: finding, source: "custom:\(name)", confidence: sessionF.confidence, emails: emails))
            }
        }
        for (subQ, sessionF) in subFindings {
            for finding in sessionF.findings {
                allFindings.append((source: subQ, finding: finding, confidence: sessionF.confidence))
                trackedFindings.append(trackEvidence(finding: finding, source: subQ, confidence: sessionF.confidence, emails: emails))
            }
        }

        let linkedCount = trackedFindings.filter { !$0.emailIDs.isEmpty }.count

        // Sort: high relevance + high confidence first
        allFindings.sort { a, b in
            let aScore = (a.finding.relevance == .high ? 3 : a.finding.relevance == .medium ? 2 : 1) + a.confidence
            let bScore = (b.finding.relevance == .high ? 3 : b.finding.relevance == .medium ? 2 : 1) + b.confidence
            return aScore > bScore
        }

        // ── Dynamic Fan-In: check if findings fit in context budget ──
        let findingsText = serializeFindings(allFindings)
        let budget = contextBudget(for: intent)
        let availableBudget = budget.findingsChars + budget.ragChars + budget.emailBodyChars

        if findingsText.count <= availableBudget {
            // ✅ Fits! Skip merge layer — go straight to synthesizer (2 layers total)
            let layerCount = 2
            await onUpdate("*Layer 2: Synthesizing \(allFindings.count) findings (\(linkedCount) linked to emails, \(layerCount)-layer pipeline)...*\n\n")

            return try await runSynthesizer(
                query: query, intent: intent, emails: emails, profile: profile,
                findingsText: findingsText, allFindings: allFindings,
                totalParallel: totalParallel, layerCount: layerCount,
                plan: plan, onUpdate: onUpdate
            )
        }

        // ── Layer 2: Merge layer needed — findings exceed budget ──
        // Group findings by relevance tier and merge low-priority ones
        let highFindings = allFindings.filter { $0.finding.relevance == .high }
        let medFindings = allFindings.filter { $0.finding.relevance == .medium }
        let lowFindings = allFindings.filter { $0.finding.relevance == .low }

        await onUpdate("*Layer 2: Merging \(medFindings.count + lowFindings.count) secondary findings...*\n\n")

        // High findings pass through directly (already compact and relevant)
        let highText = serializeFindings(highFindings)

        // Merge medium + low findings into a compressed summary via Apple AI
        let mergedText: String
        if !medFindings.isEmpty || !lowFindings.isEmpty {
            let toMerge = medFindings + lowFindings
            mergedText = await mergeFindings(findings: toMerge, query: query)
        } else {
            mergedText = ""
        }

        // Check if we need yet another layer
        let combinedText = highText + "\n\n" + mergedText
        if combinedText.count <= availableBudget {
            // ✅ Fits after 1 merge — go to synthesizer (3 layers total)
            let layerCount = 3
            await onUpdate("*Layer 3: Synthesizing across \(layerCount) layers...*\n\n")

            return try await runSynthesizer(
                query: query, intent: intent, emails: emails, profile: profile,
                findingsText: combinedText, allFindings: highFindings,
                totalParallel: totalParallel, layerCount: layerCount,
                plan: plan, onUpdate: onUpdate
            )
        }

        // ── Layer 3+: Recursive merge (rare — only for very complex queries) ──
        let truncatedCombined = String(combinedText.prefix(availableBudget))
        let layerCount = 4
        await onUpdate("*Layer \(layerCount): Deep merge — synthesizing across \(layerCount) layers...*\n\n")

        return try await runSynthesizer(
            query: query, intent: intent, emails: emails, profile: profile,
            findingsText: truncatedCombined, allFindings: highFindings,
            totalParallel: totalParallel, layerCount: layerCount,
            plan: plan, onUpdate: onUpdate
        )
    }

    // MARK: - Structured Sub-Query Execution

    private static func executeSubQueryStructured(
        subQuery: String,
        emails: [MBOXParser.RawEmail],
        profile: String
    ) async -> AISessionFindings {
        let terms = EmailNLPEngine.extractSearchTerms(from: subQuery)
        let (intent, _) = semanticClassifyIntent(subQuery)

        var results: [MBOXParser.RawEmail] = []
        if !terms.isEmpty {
            let indexed = EmailSearchIndex.shared.hybridSearch(query: subQuery, terms: terms, limit: 8)
            results = indexed.map(\.email)
        }
        if results.count < 3 {
            let spotlightHits = await SpotlightIndexer.shared.semanticSearch(query: subQuery, limit: 5)
            let spotlightIDs = Set(spotlightHits.compactMap { UUID(uuidString: $0.id) })
            let existingIDs = Set(results.map(\.id))
            for email in emails where spotlightIDs.contains(email.id) && !existingIDs.contains(email.id) {
                results.append(email)
            }
        }
        if results.isEmpty { results = Array(emails.prefix(8)) }

        let nlpStats = gatherTargetedAnalysis(intent: intent, relevant: results, all: emails)

        var context = nlpStats.isEmpty ? "" : nlpStats + "\n\n"

        // ── Improvement 3: Chunk-level retrieval for precise evidence ──
        if !terms.isEmpty && !results.isEmpty {
            let chunks = chunkLevelRetrieve(query: subQuery, terms: terms, emails: results, limit: 3)
            if !chunks.isEmpty {
                context += "KEY PASSAGES:\n"
                for (i, c) in chunks.enumerated() {
                    context += "[\(i+1)] \(c.email.headers["Subject"] ?? "?") from \(c.email.headers["From"] ?? "?"): \"\(c.bestChunk)\"\n"
                }
                context += "\n"
            }
        }

        // ── Improvement 1: Use pre-computed data if available ──
        let (precompDone, senderProfilesCopy) = fmStateQueue.sync {
            (precomputationDone, precomputedSenderProfiles)
        }
        if precompDone && !senderProfilesCopy.isEmpty {
            let qLower = subQuery.lowercased()
            let relevantSenders = senderProfilesCopy.filter { qLower.contains($0.sender.lowercased().components(separatedBy: "@").first ?? "") }
            if !relevantSenders.isEmpty {
                context += "PRE-COMPUTED SENDER DATA:\n"
                for s in relevantSenders.prefix(3) {
                    context += "• \(s.sender): \(s.count) emails, \(s.sentiment), topics: \(s.topics.joined(separator: ", "))\n"
                }
                context += "\n"
            }
        }

        for email in results.prefix(8) {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let date = email.headers["Date"] ?? ""
            let body = bodySnippet(for: email, maxLength: 200)
            context += "--- \(subj) ---\nFrom: \(from)\nDate: \(date)\nBody: \(body)\n\n"
        }

        guard isAvailable else {
            return AISessionFindings(
                findings: [AIFinding(finding: "Sub-query: \(subQuery). Found \(results.count) emails.", evidence: "", relevance: .medium)],
                summary: String(context.prefix(150)),
                confidence: 2
            )
        }

        do {
            let session = LanguageModelSession(instructions:
                "You are analyzing a focused subset of an email archive. " +
                "Extract specific, evidence-backed findings. Each finding must reference an email subject or sender. " +
                "Rate relevance: high = directly answers the question, medium = useful context, low = tangential."
            )
            let subBudget = contextBudget(for: intent)
            let truncatedContext = String(context.prefix(subBudget.emailBodyChars + subBudget.headerChars + subBudget.findingsChars + subBudget.ragChars))
            let response = try await session.respond(
                to: "Question: \(subQuery)\n\n\(truncatedContext)",
                generating: AISessionFindings.self
            )
            return response.content
        } catch {
            return AISessionFindings(
                findings: [AIFinding(finding: "Found \(results.count) emails for: \(subQuery)", evidence: "", relevance: .medium)],
                summary: String(context.prefix(150)),
                confidence: 2
            )
        }
    }

    // MARK: - Serialize Structured Findings (compact text for context)

    // v2.3.1: Confidence-weighted serialization
    private static func serializeFindings(_ findings: [(source: String, finding: AIFinding, confidence: Int)]) -> String {
        guard !findings.isEmpty else { return "" }
        var text = "RANKED FINDINGS (\(findings.count) total, sorted by relevance+confidence):\n"
        text += "Legend: ▲=high relevance ●=medium ▽=low | conf:5=ground truth, conf:1-2=needs caveat\n\n"
        for (i, entry) in findings.enumerated() {
            let relevanceIcon = entry.finding.relevance == .high ? "▲" : (entry.finding.relevance == .medium ? "●" : "▽")
            let confIcon = entry.confidence >= 4 ? "▲" : (entry.confidence >= 3 ? "●" : "▽")
            text += "[\(i+1)] \(relevanceIcon) [conf:\(confIcon)\(entry.confidence)] \(entry.finding.finding)"
            if !entry.finding.evidence.isEmpty {
                text += " | Evidence: \(entry.finding.evidence)"
            }
            text += " (from: \(entry.source))\n"
        }
        return text
    }

    // MARK: - Merge Layer (compress secondary findings via Apple AI)

    private static func mergeFindings(
        findings: [(source: String, finding: AIFinding, confidence: Int)],
        query: String
    ) async -> String {
        let input = serializeFindings(findings)

        guard isAvailable else {
            // Fallback: just take the top findings by text
            return String(input.prefix(1500))
        }

        do {
            let session = LanguageModelSession(instructions:
                "You are a merge layer in a multi-AI pipeline. " +
                "Deduplicate and compress these secondary findings into a compact summary. " +
                "Keep any finding that adds unique information to answer the question. " +
                "Remove redundant or tangential findings. " +
                "Output: merged findings with cross-session patterns noted."
            )
            let response = try await session.respond(
                to: "Question: \(query)\n\nFindings to merge:\n\(input)",
                generating: AIMergedFindings.self
            )
            let merged = response.content
            var text = "MERGED SECONDARY FINDINGS:\n"
            for f in merged.findings {
                let icon = f.relevance == .high ? "▲" : (f.relevance == .medium ? "●" : "▽")
                text += "\(icon) \(f.finding)"
                if !f.evidence.isEmpty { text += " | \(f.evidence)" }
                text += "\n"
            }
            if !merged.crossSessionInsights.isEmpty {
                text += "Cross-session patterns: \(merged.crossSessionInsights)\n"
            }
            if !merged.gaps.isEmpty {
                text += "Gaps: \(merged.gaps)\n"
            }
            return text
        } catch {
            return String(input.prefix(1500))
        }
    }

    // MARK: - Final Synthesizer (prose output from structured input)

    private static func runSynthesizer(
        query: String,
        intent: QueryIntent,
        emails: [MBOXParser.RawEmail],
        profile: String,
        findingsText: String,
        allFindings: [(source: String, finding: AIFinding, confidence: Int)],
        totalParallel: Int,
        layerCount: Int,
        plan: AIQueryPlan,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let budget = contextBudget(for: intent)
        let profileTruncated = String(profile.prefix(budget.profileChars))
        let findingsTruncated = String(findingsText.prefix(budget.findingsChars + budget.ragChars + budget.emailBodyChars))
        var reduceContext = profileTruncated + "\n\n" + findingsTruncated

        // Thread context for synthesis — helps AI understand reply chains (v2.1.3)
        let threadCtx = buildThreadContext(for: emails, query: query, maxChars: budget.headerChars / 2)
        if !threadCtx.isEmpty {
            reduceContext += "\n" + threadCtx
        }

        let convoCtx = conversationContext()
        if !convoCtx.isEmpty {
            reduceContext = String(convoCtx.prefix(budget.conversationChars)) + "\n" + reduceContext
        }
        reduceContext = String(reduceContext.prefix(contextCharBudget))

        let highCount = allFindings.filter { $0.finding.relevance == .high }.count
        let totalFindings = allFindings.count

        let highConfCount = allFindings.filter { $0.confidence >= 4 }.count
        let instructions = "Email analyst. Synthesize \(totalFindings) findings (\(highCount) high-relevance, \(highConfCount) high-confidence) from \(totalParallel) experts. " +
            "▲=high ●=medium ▽=low relevance. conf:5=ground truth (state as fact), conf:4=strong (state confidently), " +
            "conf:3=moderate (use 'likely' or 'appears to'), conf:1-2=weak (caveat with 'may' or 'possibly'). " +
            "Focus on ▲ findings with high confidence. Cite emails by **Subject** and **sender**. " +
            "Answer the user's exact question first, then add supporting insights."

        let tools = selectTools(for: intent, emails: emails)
        let session = tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)

        let prompt = "\(reduceContext)\n\nAnswer this question: \(query)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }

        recordTurn(query: query, intent: intent, answer: finalContent)
        return finalContent
    }

    // MARK: - Single-Session Path (simple queries or small archives)

    private static func respondSingleSession(
        query: String,
        intent: QueryIntent,
        searchTerms: [String],
        emails: [MBOXParser.RawEmail],
        profile: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let relevant = await smartRetrieve(intent: intent, query: query, terms: searchTerms, emails: emails)
        let nlpStats = gatherTargetedAnalysis(intent: intent, relevant: relevant, all: emails)

        // ── Improvement 3: Chunk-level retrieval for precise evidence ──
        var chunkEvidence = ""
        if !searchTerms.isEmpty && !relevant.isEmpty {
            let chunks = chunkLevelRetrieve(query: query, terms: searchTerms, emails: relevant, limit: 5)
            if !chunks.isEmpty {
                chunkEvidence = "KEY PASSAGES (most relevant excerpts):\n"
                for (i, c) in chunks.enumerated() {
                    let subj = c.email.headers["Subject"] ?? "(No Subject)"
                    let from = c.email.headers["From"] ?? "Unknown"
                    chunkEvidence += "[\(i+1)] From \(from), Re: \(subj):\n\"\(c.bestChunk)\"\n\n"
                }
            }
        }

        // Intent-aware context allocation
        let budget = contextBudget(for: intent)
        var context: String
        if emails.count >= multiSessionThreshold {
            context = String(profile.prefix(budget.profileChars)) + "\n\n"
            if !chunkEvidence.isEmpty { context += String(chunkEvidence.prefix(budget.ragChars)) + "\n" }
            let emailContext = buildBudgetedContext(
                intent: intent, query: query, relevant: relevant,
                allCount: emails.count, nlpStats: nlpStats
            )
            let remainingBudget = budget.emailBodyChars + budget.headerChars
            context += String(emailContext.prefix(remainingBudget))
        } else {
            context = ""
            if !chunkEvidence.isEmpty { context += String(chunkEvidence.prefix(budget.ragChars)) + "\n" }
            context += buildBudgetedContext(
                intent: intent, query: query, relevant: relevant,
                allCount: emails.count, nlpStats: nlpStats
            )
        }

        let convoCtx = conversationContext()
        if !convoCtx.isEmpty {
            let convoTruncated = String(convoCtx.prefix(budget.conversationChars))
            context = convoTruncated + "\n" + context
        }

        let instructions = focusedInstructions(for: intent)

        let tools = selectTools(for: intent, emails: emails)
        let session = tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)

        let prompt = "User question: \(query)\n\n\(context)"

        let stream = session.streamResponse(to: prompt)
        var finalContent = ""
        for try await snapshot in stream {
            finalContent = snapshot.content
            await onUpdate(finalContent)
        }

        recordTurn(query: query, intent: intent, answer: finalContent)
        return finalContent
    }

    private static func smartRetrieve(
        intent: QueryIntent,
        query: String,
        terms: [String],
        emails: [MBOXParser.RawEmail]
    ) async -> [MBOXParser.RawEmail] {
        let limit = intent.maxEmails
        guard limit > 0 else { return [] }

        switch intent {
        case .search, .general:
            // Layer 1: BM25 + semantic search from our index
            var found: [MBOXParser.RawEmail] = []
            if !terms.isEmpty {
                let results = EmailSearchIndex.shared.hybridSearch(query: query, terms: terms, limit: limit)
                found = results.map(\.email)
            }

            // Layer 2: Spotlight semantic search (Apple Intelligence powered)
            let spotlightResults = await SpotlightIndexer.shared.semanticSearch(query: query, limit: limit)
            if !spotlightResults.isEmpty {
                let spotlightIDs = Set(spotlightResults.compactMap { UUID(uuidString: $0.id) })
                let spotlightEmails = emails.filter { spotlightIDs.contains($0.id) }
                let existingIDs = Set(found.map(\.id))
                for email in spotlightEmails where !existingIDs.contains(email.id) {
                    found.append(email)
                }
            }

            if found.count >= 2 { return Array(found.prefix(limit)) }

            if !terms.isEmpty {
                let fallback = EmailNLPEngine.searchEmails(terms: terms, in: emails, limit: limit)
                if !fallback.isEmpty { return fallback.map(\.email) }
            }
            return Array(emails.prefix(limit))

        case .thread:
            let threads = ThreadGrouper.group(emails)
            if !terms.isEmpty {
                for term in terms {
                    let lower = term.lowercased()
                    if let thread = threads.first(where: { $0.subject.lowercased().contains(lower) }) {
                        return Array(thread.allEmails.sorted {
                            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
                            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
                        }.prefix(limit))
                    }
                }
            }
            let results = EmailSearchIndex.shared.hybridSearch(query: query, terms: terms, limit: 5)
            if !results.isEmpty {
                let expanded = EmailSearchIndex.shared.expandByThread(results.map(\.email), allEmails: emails)
                return Array(expanded.prefix(limit))
            }
            return Array(emails.prefix(limit))

        case .entity:
            var found: [MBOXParser.RawEmail] = []
            let nameFromQuery = extractPersonName(from: query)
            if let name = nameFromQuery {
                found = EmailNLPEngine.fuzzyMatchContacts(name: name, in: emails)
            }
            if found.count < 2 && !terms.isEmpty {
                let results = EmailSearchIndex.shared.hybridSearch(query: query, terms: terms, limit: limit)
                let existingIDs = Set(found.map(\.id))
                for r in results where !existingIDs.contains(r.email.id) {
                    found.append(r.email)
                }
            }
            // Enrich with Spotlight semantic search
            let spotlightHits = await SpotlightIndexer.shared.semanticSearch(query: query, limit: 5)
            let spotlightIDs = Set(spotlightHits.compactMap { UUID(uuidString: $0.id) })
            let existingIDs = Set(found.map(\.id))
            for email in emails where spotlightIDs.contains(email.id) && !existingIDs.contains(email.id) {
                found.append(email)
            }
            return found.isEmpty ? Array(emails.prefix(limit)) : Array(found.prefix(limit))

        case .security:
            let flagged = EmailNLPEngine.detectPhishing(in: emails)
            var result = flagged.prefix(limit).map(\.email)
            if result.count < limit {
                let safe = emails.filter { e in !result.contains(where: { $0.id == e.id }) }
                result += Array(safe.prefix(limit - result.count))
            }
            return result

        case .triage:
            let replyCount: [String: Int] = Dictionary(
                emails.compactMap { $0.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .map { ($0, 1) },
                uniquingKeysWith: +
            )
            let priorities = EmailNLPEngine.scoreAllPriorities(emails, replyCountPerSender: replyCount)
            return Array(priorities.prefix(limit).map(\.email))

        case .sentiment:
            let sentiments = EmailNLPEngine.analyzeSentiment(of: emails)
            let positive = Array(sentiments.filter { $0.score > 0.1 }.prefix(3))
            let negative = Array(sentiments.filter { $0.score < -0.1 }.prefix(3))
            let neutral = Array(sentiments.filter { abs($0.score) <= 0.1 }.prefix(2))
            return (positive + negative + neutral).map(\.email)

        case .summary:
            if !terms.isEmpty {
                let results = EmailSearchIndex.shared.hybridSearch(query: query, terms: terms, limit: limit)
                if results.count >= 3 { return results.map(\.email) }
            }
            // Diverse sample: first few + last few + random middle
            if emails.count <= limit { return emails }
            let first = Array(emails.prefix(4))
            let last = Array(emails.suffix(4))
            let middle = Array(emails.dropFirst(4).dropLast(4).prefix(limit - 8))
            var unique: [MBOXParser.RawEmail] = []
            var seen = Set<UUID>()
            for e in (first + middle + last) where !seen.contains(e.id) {
                seen.insert(e.id)
                unique.append(e)
            }
            return Array(unique.prefix(limit))

        case .topicAnalysis, .temporal:
            return Array(emails.prefix(limit))

        case .statistics:
            return []
        }
    }

    private static func extractPersonName(from query: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = query
        var name: String?
        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, range in
            if tag == .personalName || tag == .organizationName {
                name = String(query[range])
                return false
            }
            return true
        }
        return name
    }

    private static func gatherTargetedAnalysis(
        intent: QueryIntent,
        relevant: [MBOXParser.RawEmail],
        all: [MBOXParser.RawEmail]
    ) -> String {
        let target = relevant.isEmpty ? all : relevant
        var stats = ""
        let sent = all.filter { $0.messageType == "sent" }.count
        let recv = all.filter { $0.messageType == "received" }.count
        stats += "Archive: \(all.count) emails (\(sent) sent, \(recv) received)"

        let dates = all.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        if let first = dates.first, let last = dates.last {
            let f = DateFormatter()
            f.dateStyle = .medium
            stats += ", \(f.string(from: first)) to \(f.string(from: last))"
        }

        switch intent {
        case .sentiment:
            let s = EmailNLPEngine.averageSentiment(of: target)
            stats += "\nSentiment: \(s.label) (avg \(String(format: "%.2f", s.average))). Positive: \(s.positive), Neutral: \(s.neutral), Negative: \(s.negative)"

        case .topicAnalysis, .summary:
            let topics = EmailNLPEngine.extractTopics(from: target, limit: 8)
            let classification = EmailNLPEngine.classifyAll(target)
            if !topics.isEmpty {
                stats += "\nTopics: \(topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: ", "))"
            }
            let catStrs = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> String? in
                guard let count = classification[cat], count > 0 else { return nil }
                return "\(cat.rawValue): \(count)"
            }
            if !catStrs.isEmpty { stats += "\nCategories: \(catStrs.joined(separator: ", "))" }

            if intent == .summary {
                let s = EmailNLPEngine.averageSentiment(of: target)
                stats += "\nSentiment: \(s.label) (\(String(format: "%.2f", s.average)))"
            }

        case .entity:
            let contacts = EmailNLPEngine.contactInsights(from: target, limit: 8)
            if !contacts.isEmpty {
                stats += "\nContacts: " + contacts.map { "\($0.address) (\($0.emailCount) emails, \($0.sentimentLabel))" }.joined(separator: "; ")
            }

        case .security:
            let pii = EmailNLPEngine.piiSummary(in: target)
            let phishing = EmailNLPEngine.detectPhishing(in: target)
            stats += "\nPhishing flags: \(phishing.count)"
            if !pii.isEmpty { stats += "\nPII: " + pii.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ") }

        case .triage:
            let replyCount: [String: Int] = Dictionary(
                target.compactMap { $0.headers["From"]?.trimmingCharacters(in: .whitespacesAndNewlines) }.map { ($0, 1) },
                uniquingKeysWith: +
            )
            let priorities = EmailNLPEngine.scoreAllPriorities(target, replyCountPerSender: replyCount)
            let high = priorities.filter { $0.level == .high }.count
            let med = priorities.filter { $0.level == .medium }.count
            stats += "\nPriority: \(high) high, \(med) medium"

        case .statistics:
            let s = EmailNLPEngine.averageSentiment(of: all)
            let topics = EmailNLPEngine.extractTopics(from: all, limit: 8)
            let classification = EmailNLPEngine.classifyAll(all)
            let contacts = EmailNLPEngine.contactInsights(from: all, limit: 5)
            stats += "\nSentiment: \(s.label) (avg \(String(format: "%.2f", s.average))). Positive: \(s.positive), Neutral: \(s.neutral), Negative: \(s.negative)"
            if !topics.isEmpty { stats += "\nTopics: \(topics.map(\.word).joined(separator: ", "))" }
            let catStrs = EmailNLPEngine.EmailCategory.allCases.compactMap { c -> String? in
                guard let n = classification[c], n > 0 else { return nil }; return "\(c.rawValue): \(n)"
            }
            if !catStrs.isEmpty { stats += "\nCategories: \(catStrs.joined(separator: ", "))" }
            if !contacts.isEmpty { stats += "\nTop contacts: \(contacts.prefix(5).map { "\($0.address) (\($0.emailCount))" }.joined(separator: ", "))" }

        case .temporal:
            let topics = EmailNLPEngine.extractTopics(from: target, limit: 5)
            if !topics.isEmpty { stats += "\nKey topics: \(topics.map(\.word).joined(separator: ", "))" }
            let s = EmailNLPEngine.averageSentiment(of: target)
            stats += "\nSentiment: \(s.label)"

        case .search, .thread, .general:
            break
        }

        return stats
    }

    private static func buildBudgetedContext(
        intent: QueryIntent,
        query: String,
        relevant: [MBOXParser.RawEmail],
        allCount: Int,
        nlpStats: String
    ) -> String {
        var context = ""
        let intentBudget = contextBudget(for: intent)
        let budget = intentBudget.emailBodyChars + intentBudget.headerChars + intentBudget.findingsChars

        // NLP stats first — compact, high value
        if !nlpStats.isEmpty {
            context += nlpStats + "\n\n"
        }

        guard intent != .statistics else { return context }

        let maxEmails = intent.maxEmails
        var maxSnippet = intent.maxSnippetChars
        let emailsToUse = Array(relevant.prefix(maxEmails))

        if relevant.count < allCount {
            context += "Showing \(emailsToUse.count) most relevant of \(allCount) total:\n\n"
        }

        // First pass: estimate total size
        var entries: [(header: String, body: String)] = []
        for email in emailsToUse {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? "Unknown"
            let date = email.headers["Date"] ?? ""
            let header = "--- \(subj) ---\nFrom: \(from)\nDate: \(date)"
            let body = bodySnippet(for: email, maxLength: maxSnippet)
            entries.append((header: header, body: body))
        }

        let totalChars = entries.reduce(0) { $0 + $1.header.count + $1.body.count + 10 }
        let remainingBudget = budget - context.count

        // If too large, compress snippet lengths proportionally
        if totalChars > remainingBudget {
            let ratio = Double(remainingBudget) / Double(max(1, totalChars))
            maxSnippet = max(80, Int(Double(maxSnippet) * ratio))

            // Re-build with compressed snippets
            entries = emailsToUse.map { email in
                let subj = email.headers["Subject"] ?? "(No Subject)"
                let from = email.headers["From"] ?? "Unknown"
                let date = email.headers["Date"] ?? ""
                let header = "--- \(subj) ---\nFrom: \(from)\nDate: \(date)"
                let body = bodySnippet(for: email, maxLength: maxSnippet)
                return (header: header, body: body)
            }

            // If still too large after compression, reduce email count
            var charAccum = 0
            var keepCount = entries.count
            for (i, entry) in entries.enumerated() {
                charAccum += entry.header.count + entry.body.count + 10
                if charAccum > remainingBudget {
                    keepCount = i
                    break
                }
            }
            if keepCount < entries.count {
                let dropped = entries.count - keepCount
                entries = Array(entries.prefix(keepCount))
                context += "(Showing \(keepCount) emails, \(dropped) omitted to fit context)\n\n"
            }
        }

        // Build final email context
        for entry in entries {
            context += entry.header + "\nBody: " + entry.body + "\n\n"
        }

        return context
    }

    private static func focusedInstructions(for intent: QueryIntent) -> String {
        let base = "Email analyst in mailin (on-device, private). Cite emails by **Subject** and **sender**. Use tools proactively. "
        switch intent {
        case .search:
            return base + "Search task. Use spotlightSearch + searchEmails. Show matching emails with evidence."
        case .statistics:
            return base + "Stats task. Use analyzeEmails for exact numbers. Present with percentages."
        case .sentiment:
            return base + "Sentiment task. Use analyzeEmails(sentiment). Show tone patterns with examples."
        case .summary:
            return base + "Summary task. Use analyzeEmails for topics/sentiment/categories. Cover themes, contacts, patterns in 3-4 paragraphs."
        case .security:
            return base + "Security task. Use analyzePhishing. Explain each risk in plain language."
        case .triage:
            return base + "Triage task. Use analyzeEmails(priority). Group: Act Now, Today, This Week."
        case .thread:
            return base + "Thread task. Use getThread. Narrate chronologically with decisions and turning points."
        case .entity:
            return base + "Person profile. Use lookupContact + spotlightSearch. Cover: role, frequency, sentiment, topics."
        case .topicAnalysis:
            return base + "Topic task. Use analyzeEmails(topics). List themes with email evidence."
        case .temporal:
            return base + "Time analysis. Show volume trends, topic shifts, sentiment changes over time."
        case .general:
            return base + "Answer the question using all tools: spotlightSearch, searchEmails, getThread, lookupContact, analyzeEmails, analyzePhishing."
        }
    }

    // MARK: - AI-Powered Archive Comparison (v3.6.1)

    struct ArchiveComparisonResult {
        let communicationPatterns: String
        let topicDrift: String
        let sentimentShift: String
        let relationshipChanges: String
        let kgComparison: KnowledgeGraph.GraphComparison?
        let synthesis: String
    }

    static func compareArchives(
        archiveA: [MBOXParser.RawEmail],
        archiveB: [MBOXParser.RawEmail],
        nameA: String,
        nameB: String,
        query: String? = nil,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async -> ArchiveComparisonResult {
        await onUpdate("*Comparing archives: analyzing communication patterns...*")

        // Parallel NLP analysis of both archives
        let topicsA = EmailNLPEngine.extractTopics(from: archiveA, limit: 15)
        let topicsB = EmailNLPEngine.extractTopics(from: archiveB, limit: 15)
        let sentA = EmailNLPEngine.averageSentiment(of: archiveA)
        let sentB = EmailNLPEngine.averageSentiment(of: archiveB)
        let entitiesA = EmailNLPEngine.extractEntities(from: archiveA, limit: 15)
        let entitiesB = EmailNLPEngine.extractEntities(from: archiveB, limit: 15)

        // Communication patterns
        let sendersA = Dictionary(grouping: archiveA, by: { $0.headers["From"]?.lowercased() ?? "?" })
        let sendersB = Dictionary(grouping: archiveB, by: { $0.headers["From"]?.lowercased() ?? "?" })
        let uniqueToA = Set(sendersA.keys).subtracting(Set(sendersB.keys))
        let uniqueToB = Set(sendersB.keys).subtracting(Set(sendersA.keys))
        let commonSenders = Set(sendersA.keys).intersection(Set(sendersB.keys))

        var commPatterns = "COMMUNICATION PATTERNS:\n"
        commPatterns += "\(nameA): \(archiveA.count) emails, \(sendersA.count) unique senders\n"
        commPatterns += "\(nameB): \(archiveB.count) emails, \(sendersB.count) unique senders\n"
        commPatterns += "Common senders: \(commonSenders.count), Only in \(nameA): \(uniqueToA.count), Only in \(nameB): \(uniqueToB.count)\n"

        let volumeChangePercent = archiveA.isEmpty ? 0 : ((Double(archiveB.count) - Double(archiveA.count)) / Double(archiveA.count)) * 100
        commPatterns += "Volume change: \(String(format: "%+.0f%%", volumeChangePercent))\n"

        await onUpdate("*Analyzing topic drift...*")

        // Topic drift
        let topicSetA = Set(topicsA.map { $0.word.lowercased() })
        let topicSetB = Set(topicsB.map { $0.word.lowercased() })
        let newTopics = topicSetB.subtracting(topicSetA)
        let droppedTopics = topicSetA.subtracting(topicSetB)

        var topicDrift = "TOPIC DRIFT:\n"
        topicDrift += "\(nameA) topics: \(topicsA.prefix(8).map(\.word).joined(separator: ", "))\n"
        topicDrift += "\(nameB) topics: \(topicsB.prefix(8).map(\.word).joined(separator: ", "))\n"
        if !newTopics.isEmpty {
            topicDrift += "NEW topics in \(nameB): \(newTopics.prefix(5).joined(separator: ", "))\n"
        }
        if !droppedTopics.isEmpty {
            topicDrift += "DROPPED topics from \(nameA): \(droppedTopics.prefix(5).joined(separator: ", "))\n"
        }

        // Sentiment shift
        let sentShift = sentB.average - sentA.average
        let sentDirection = sentShift > 0.1 ? "more positive" : sentShift < -0.1 ? "more negative" : "stable"
        var sentimentText = "SENTIMENT SHIFT:\n"
        sentimentText += "\(nameA): \(sentA.label) (\(String(format: "%.2f", sentA.average))), +\(sentA.positive)/~\(sentA.neutral)/-\(sentA.negative)\n"
        sentimentText += "\(nameB): \(sentB.label) (\(String(format: "%.2f", sentB.average))), +\(sentB.positive)/~\(sentB.neutral)/-\(sentB.negative)\n"
        sentimentText += "Shift: \(sentDirection) (\(String(format: "%+.2f", sentShift)))\n"

        await onUpdate("*Building and comparing knowledge graphs...*")

        // Relationship changes via KG comparison
        let graphA = KnowledgeGraph()
        KnowledgeGraphBuilder.build(from: archiveA, into: graphA)
        let graphB = KnowledgeGraph()
        KnowledgeGraphBuilder.build(from: archiveB, into: graphB)
        let kgComp = graphA.compare(to: graphB)

        var relationText = "RELATIONSHIP CHANGES:\n"
        relationText += kgComp.summaryText()
        if relationText == "RELATIONSHIP CHANGES:\n" {
            relationText += "No significant relationship changes detected.\n"
        }

        // Entity comparison
        let entitySetA = Set(entitiesA.map { $0.name.lowercased() })
        let entitySetB = Set(entitiesB.map { $0.name.lowercased() })
        let newEntities = entitySetB.subtracting(entitySetA)
        let lostEntities = entitySetA.subtracting(entitySetB)
        if !newEntities.isEmpty {
            relationText += "NEW entities in \(nameB): \(newEntities.prefix(5).joined(separator: ", "))\n"
        }
        if !lostEntities.isEmpty {
            relationText += "GONE from \(nameA): \(lostEntities.prefix(5).joined(separator: ", "))\n"
        }

        await onUpdate("*Synthesizing comparison...*")

        // AI synthesis
        var synthesis = ""
        if isAvailable {
            do {
                let context = [commPatterns, topicDrift, sentimentText, relationText].joined(separator: "\n")
                let session = LanguageModelSession(instructions:
                    "You compare two email archives. Highlight: what changed, what's new, what disappeared, notable trends. " +
                    "Use markdown headings and bullets. Be specific — cite names, topics, numbers."
                )
                let focusClause = query.map { "Focus on: \($0). " } ?? ""
                let prompt = "\(focusClause)Compare these archives:\n\n\(String(context.prefix(3000)))"
                let stream = session.streamResponse(to: prompt)
                for try await snapshot in stream {
                    synthesis = snapshot.content
                    await onUpdate(synthesis)
                }
            } catch {
                synthesis = "**\(nameA) vs \(nameB)**\n\n" + commPatterns + "\n" + topicDrift + "\n" + sentimentText + "\n" + relationText
            }
        } else {
            synthesis = "**\(nameA) vs \(nameB)**\n\n" + commPatterns + "\n" + topicDrift + "\n" + sentimentText + "\n" + relationText
        }

        return ArchiveComparisonResult(
            communicationPatterns: commPatterns,
            topicDrift: topicDrift,
            sentimentShift: sentimentText,
            relationshipChanges: relationText,
            kgComparison: kgComp,
            synthesis: synthesis
        )
    }
}

#endif
