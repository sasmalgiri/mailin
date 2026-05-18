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
            You are an expert email analyst. The user imported their email archive into mailin, \
            a privacy-first Mac app. All processing is 100% on-device.

            Your role:
            - Answer thoroughly with specific evidence from the emails
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never as \
              "Email 1" or "Email 2". For example say "**Q1 Product Launch Strategy** from \
              **Sarah Johnson**" not "Email 1"
            - Use **bold** for names, dates, and key terms
            - Quote relevant email content directly
            - Synthesize information across multiple emails into coherent insights
            - Note patterns, trends, and connections you observe
            - If data is insufficient, state what you can determine and what's uncertain
            - Be conversational and insightful — like a colleague who read every email
            - Use bullet points and clear structure for complex answers
            - If the user asks about something not in the provided emails, use the searchEmails \
              tool to find more relevant emails
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

        let instructions = """
            You are an expert email analyst in mailin, a privacy-first Mac app. \
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
            - Be conversational like a colleague who read every email
            - Connect dots across emails — identify patterns and insights
            - If you notice something interesting the user didn't ask about, mention it briefly
            - Keep responses focused and evidence-based
            - Use the searchEmails tool if you need more context beyond the provided emails
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

        let instructions = """
            You are an expert email analyst in mailin, a privacy-first Mac app. \
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
            - Be conversational and insightful — like a colleague who read every email carefully
            - Structure complex answers with bullet points or numbered lists
            - If you notice something interesting the user didn't ask about, mention it briefly
            - Keep responses focused and evidence-based — every claim should trace to an email
            - Use the searchEmails tool if you need more context beyond the provided emails
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

        // Dynamic fan-in
        let findingsText = serializeFindings(allFindings)
        let profileBudget = min(profile.count, contextCharBudget / 4)
        let ragBudget = contextCharBudget / 4
        let availableBudget = contextCharBudget - profileBudget - ragBudget - 500

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
        let instructions = """
            You are the AI brain of mailin, a privacy-first email app. \
            A \(layerCount)-layer hybrid pipeline has been deployed: \
            NLP computed a deterministic baseline answer, agentic RAG retrieved \(ragRetrievedEmails.count) emails \
            with chunk-level evidence, \(totalWithCloud) parallel expert sessions (\(experts.count) on-device + \(cloudExpertCount) cloud) produced \
            \(allFindings.count) structured findings (\(highCount) high-relevance, \(linkedCount) linked to source emails). \
            \
            Your job: synthesize ALL of this into one coherent, evidence-rich answer that IMPROVES on the NLP baseline. \
            The NLP baseline has verified numbers — use them as ground truth. \
            Expert findings (marked ▲/●/▽) add depth and insight beyond what NLP can compute. \
            Cloud expert findings bring world knowledge and external context that on-device models lack. \
            KEY PASSAGES are the most relevant email excerpts — quote them directly. \
            \
            Rules: \
            - Refer to emails by **Subject** and **sender** in bold, never as "Email 1" \
            - Every claim must trace to an email or finding \
            - Use the NLP baseline numbers as-is (they are deterministic truth) \
            - Add expert insights that go beyond what the baseline found \
            - Integrate cloud expert world-knowledge insights where they add unique value \
            - Be conversational, like a colleague who analyzed everything thoroughly \
            - Structure with bullet points or numbered lists for complex answers
            """

        let tools = selectTools(for: intent, emails: targetEmails)
        let session = tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)

        let prompt = "User question: \(query)\n\n\(synthesisContext)"

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

    // MARK: - Conversation Memory (on-device, in-memory only)

    struct ConversationTurn {
        let query: String
        let intent: QueryIntent
        let answerSnippet: String
        let entities: [String]
        let topics: [String]
        let queryTerms: [String]
    }

    private nonisolated static let fmStateQueue = DispatchQueue(label: "com.mailin.fmState")
    nonisolated(unsafe) private static var conversationHistory: [ConversationTurn] = []
    private static let maxHistoryTurns = 5

    static func clearConversationMemory() {
        fmStateQueue.sync { conversationHistory.removeAll() }
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
        }
    }

    private static func conversationContext() -> String {
        let historyCopy = fmStateQueue.sync { conversationHistory }
        guard !historyCopy.isEmpty else { return "" }
        var ctx = "CONVERSATION MEMORY:\n"
        for (i, turn) in historyCopy.enumerated() {
            ctx += "Turn \(i + 1): \(turn.query) [\(turn.intent)]\n"
            if !turn.entities.isEmpty {
                ctx += "  People/Orgs: \(turn.entities.joined(separator: ", "))\n"
            }
            if !turn.topics.isEmpty {
                ctx += "  Topics: \(turn.topics.joined(separator: ", "))\n"
            }
            ctx += "  Answer: \(turn.answerSnippet)\n\n"
        }
        return ctx
    }

    // MARK: - AI Intent Classification

    static func classifyIntent(_ query: String) async -> QueryIntent {
        // Try Apple AI structured classification first
        if let aiIntent = await classifyIntentWithAI(query) {
            return aiIntent
        }
        return classifyIntentKeyword(query)
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
                You are an AI email assistant built into mailin, a privacy-first Mac app for email archives. \
                You run entirely on-device using Apple Intelligence — no data leaves the device. \
                \
                Your capabilities: \
                - Search emails by keyword, sender, date, topic, or natural language \
                - Analyze sentiment, tone, and communication patterns \
                - Detect phishing, scams, and sensitive data (PII) \
                - Summarize email threads and generate insights \
                - Triage emails by priority and urgency \
                - Topic clustering and trend analysis \
                - Export, print, and forensic analysis \
                \
                You have a 4-engine AI architecture: Apple AI MoE (multi-expert), Apple AI Direct, \
                Hybrid (NLP + Apple AI), and NLP Pure. You use NLP for fast deterministic analysis \
                and Apple AI for nuanced understanding. \
                \
                The user currently has \(emailCount) emails loaded. \
                \
                If the user's message is conversational (greeting, about-you, capability question, \
                chit-chat, acknowledgment), respond naturally and helpfully. Keep it concise — \
                2-4 sentences max. Use markdown bold for emphasis. \
                \
                If the message is actually asking about their emails (search, analyze, filter, etc.), \
                set isConversational to false and leave response empty.
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
           q.contains("percentage") || q.contains("ratio") {
            if !q.contains("sentiment") && !q.contains("tone") { return .statistics }
        }

        if q.contains("phishing") || q.contains("suspicious") || q.contains("scam") ||
           q.contains("spam") || q.contains("fraud") || q.contains("pii") ||
           q.contains("sensitive data") || (q.contains("security") && q.contains("email")) {
            return .security
        }

        if q.contains("sentiment") || q.contains("tone") || q.contains("mood") ||
           q.contains("feeling") || q.contains("emotion") {
            return .sentiment
        }

        if q.contains("thread") || q.contains("conversation about") || q.contains("discussion about") ||
           q.contains("what happened with") {
            return .thread
        }

        if q.contains("triage") || q.contains("priority") || q.contains("urgent") ||
           ((q.contains("important") || q.contains("action")) && q.contains("email")) {
            return .triage
        }

        if (q.contains("who") && (q.contains("most") || q.contains("frequently") || q.contains("contact"))) ||
           q.contains("people") || q.contains("contacts") {
            return .entity
        }

        if q.contains("topic") || q.contains("theme") || q.contains("keyword") ||
           q.contains("discuss") || q.contains("about what") || q.contains("talk about") {
            return .topicAnalysis
        }

        if q.contains("trend") || q.contains("over time") || q.contains("pattern") ||
           q.contains("weekly") || q.contains("monthly") || q.contains("daily") {
            return .temporal
        }

        if q.contains("summarize") || q.contains("summary") || q.contains("overview") ||
           q.contains("digest") || q.contains("brief me") {
            return .summary
        }

        if q.contains("find") || q.contains("search") || q.contains("show me") ||
           q.contains("look for") || q.contains("emails about") || q.contains("emails from") ||
           q.contains("messages from") {
            return .search
        }

        return .general
    }

    private static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    // The usable context budget: 4096 total minus instructions, tools, query, and response space
    private static let contextCharBudget = 9000

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

        case .search:
            tools.append(SpotlightSearchTool())
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(GetThreadInfoTool(emails: emails))
            tools.append(ContactLookupTool())
            tools.append(TopicDrillTool(emails: emails))

        case .thread:
            tools.append(GetThreadInfoTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))
            tools.append(SpotlightSearchTool())

        case .summary:
            tools.append(TopicDrillTool(emails: emails))
            tools.append(SenderProfileTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(SpotlightSearchTool())
            tools.append(SearchEmailsTool(emails: emails))

        case .sentiment:
            tools.append(SenderProfileTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))

        case .topicAnalysis:
            tools.append(TopicDrillTool(emails: emails))
            tools.append(NLPAnalysisTool(emails: emails))
            tools.append(SearchEmailsTool(emails: emails))

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
        }
    }

    static func invalidatePrecomputation() {
        fmStateQueue.sync {
            precomputedSenderProfiles = []
            precomputedSecurityScan = nil
            precomputedTopicClusters = []
            precomputedTimeline = []
            precomputationDone = false
        }
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
        limit: Int
    ) -> [(email: MBOXParser.RawEmail, bestChunk: String)] {
        let chunkResults = EmailSearchIndex.shared.chunkSearch(
            terms: terms, in: emails, maxChunksPerEmail: 1, limit: limit
        )
        return chunkResults.map { (email: $0.email, bestChunk: $0.chunk) }
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
    }

    static func validateAnswer(
        answer: String,
        query: String,
        intent: QueryIntent
    ) async -> (confident: Bool, gap: String?) {
        // Quick NLP-based check first (no AI cost)
        let nlpRating = rateResult(answer: answer, query: query, source: "synthesizer")
        if nlpRating.stars >= 4 { return (true, nil) }

        // If NLP says weak, ask Apple AI for specific gap identification
        guard isAvailable else { return (nlpRating.stars >= 3, nil) }

        do {
            let session = LanguageModelSession(instructions:
                "You are a quality checker. Assess if an answer properly addresses the question. " +
                "Rate confidence 1-5. If missing key info, say exactly what's missing."
            )
            let prompt = "Question: \(query)\n\nAnswer:\n\(String(answer.prefix(1500)))"
            let response = try await session.respond(to: prompt, generating: AIAnswerValidation.self)
            let validation = response.content

            if validation.confidence >= 4 || !validation.needsRetry {
                return (true, nil)
            }
            return (false, validation.missingInfo)
        } catch {
            return (nlpRating.stars >= 3, nil)
        }
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

    private static let multiSessionThreshold = 500

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
        let intent = classifyIntentKeyword(subQuery)

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

        let nlpStats = gatherTargetedAnalysis(intent: intent, relevant: results, all: emails)

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

    // MARK: - respondSmart (unified entry point — all 7 improvements integrated)

    static func respondSmart(
        to query: String,
        emails: [MBOXParser.RawEmail],
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
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

        let intent = await classifyIntent(query)
        let searchTerms = EmailNLPEngine.extractSearchTerms(from: query)
        let profile = archiveProfile(emails: emails)

        // ── Improvement 6: Adaptive Session Count ──
        let sessionConfig = computeSessionCount(query: query, emails: emails, intent: intent)

        // For large archives, try multi-session chain for complex queries
        if emails.count >= multiSessionThreshold {
            // ── Improvement 5: Try NLP decomposition first (deterministic), then AI planning ──
            let nlpSubQueries = decomposeQueryNLP(query, emails: emails)
            let plan: AIQueryPlan?

            if nlpSubQueries.count >= 2 {
                // NLP found clear structure — use it directly (skip AI planning)
                let capped = Array(nlpSubQueries.prefix(sessionConfig.maxSubQueries))
                plan = AIQueryPlan(needsMultiStep: true, subQueries: capped, synthesisGoal: "Answer: \(query)")
            } else {
                // Fall back to AI-based planning
                plan = await planQuery(query: query, profile: profile)
            }

            if let plan, plan.needsMultiStep, !plan.subQueries.isEmpty {
                let answer = try await respondMultiSession(
                    query: query, plan: plan, intent: intent,
                    emails: emails, profile: profile, onUpdate: onUpdate
                )

                // ── Improvement 4: Self-Correction Loop ──
                let (confident, gap) = await validateAnswer(answer: answer, query: query, intent: intent)
                if !confident, let gap, !gap.isEmpty {
                    let truncatedGap = String(gap.prefix(200))
                    let retryTerms = EmailNLPEngine.extractSearchTerms(from: truncatedGap)
                    if !retryTerms.isEmpty {
                        let supplement = try await respondSingleSession(
                            query: "\(query) — specifically: \(truncatedGap)",
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

                // ── Cache the answer ──
                cacheAnswer(query: query, answer: answer, intent: intent, emailCount: emails.count)
                return answer
            }
        }

        // Single-session path (small archives or simple queries)
        let answer = try await respondSingleSession(
            query: query, intent: intent, searchTerms: searchTerms,
            emails: emails, profile: profile, onUpdate: onUpdate
        )

        // Cache single-session answers too
        cacheAnswer(query: query, answer: answer, intent: intent, emailCount: emails.count)
        return answer
    }

    // MARK: - Multi-Session Chain (Plan → Map → Reduce → Stream)

    // MARK: - Parallel Expert Sessions

    private enum ExpertRole: String, CaseIterable {
        case sentimentExpert
        case entityExpert
        case topicExpert
        case timelineExpert
        case securityExpert
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

            // Anomalies from AnomalyDetectionEngine
            let anomalies = AnomalyDetectionEngine.detectAnomalies(in: emails)
            let timeAnomalies = anomalies.filter { $0.type == .frequencySpike || $0.type == .unusualHour }
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

            // PII findings with detail
            if !piiSummary.isEmpty {
                d += "PII EXPOSURE: " + piiSummary.map { "\($0.key.rawValue): \($0.value) instance(s)" }.joined(separator: ", ") + "\n"
            }
            if !piiFindings.isEmpty {
                d += "PII DETAIL: " + piiFindings.prefix(3).map {
                    "\($0.type.rawValue) in \"\($0.emailSubject)\""
                }.joined(separator: "; ") + "\n"
            }

            // Anomalies from AnomalyDetectionEngine
            let anomalies = AnomalyDetectionEngine.detectAnomalies(in: emails)
            let securityAnomalies = anomalies.filter { $0.type == .newDomain || $0.type == .recipientAnomaly || $0.type == .largeAttachment }
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

            nlpData = d
            expertType = "cybersecurity and data protection"
        }

        // Domain-specific AI instructions per expert
        let expertInstructions: String
        switch role {
        case .sentimentExpert:
            expertInstructions = """
                You are a senior sentiment and emotional intelligence analyst specializing in email forensics. \
                Analyze emotional valence (positive/negative/neutral) and arousal (calm to urgent) for each message. \
                Detect tone escalation chains: trace how sentiment shifts across a thread from polite to confrontational. \
                Identify passive-aggressive language, sarcasm markers, and veiled hostility that surface-level analysis misses. \
                Grade relationship health between sender pairs: stable, warming, cooling, or deteriorating. \
                Flag emotional anomalies: a normally professional sender becoming emotional, or vice versa. \
                Distinguish professional dissatisfaction from personal conflict. \
                Note power dynamics revealed by tone: deference, authority, peer equality, or insubordination. \
                Output format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .entityExpert:
            expertInstructions = """
                You are a senior communication network analyst specializing in organizational intelligence from email. \
                Map the communication hierarchy: identify decision-makers, gatekeepers, influencers, and information brokers. \
                Detect organizational structure from email patterns: who reports to whom, team boundaries, cross-team liaisons. \
                Identify key contacts by influence (not just volume): who triggers action, whose emails get fast replies. \
                Flag network anomalies: isolated nodes who should be connected, unexpected bridges between groups, sudden disconnections. \
                Detect role changes: someone who shifts from CC to TO, or stops appearing in threads they previously dominated. \
                Map domain affiliations to identify external partners, vendors, clients, and competitors. \
                Note BCC patterns and distribution list usage for hidden communication channels. \
                Output format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .topicExpert:
            expertInstructions = """
                You are a senior content and thematic analyst specializing in email intelligence. \
                Build a topic taxonomy from the corpus: major themes, sub-topics, and cross-cutting concerns. \
                Track topic lifecycle: emergence, growth, peak activity, decline, and resolution or abandonment. \
                Identify decision points: emails where topics shift from discussion to action or from consensus to disagreement. \
                Detect topic ownership: which senders drive which conversations, and who gets pulled in versus who initiates. \
                Flag urgency signals: deadline mentions, escalation language, priority markers, and follow-up requests. \
                Note topic correlation: which subjects tend to co-occur, suggesting linked projects or dependencies. \
                Identify information gaps: topics mentioned but never resolved, questions asked but never answered. \
                Output format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .timelineExpert:
            expertInstructions = """
                You are a senior temporal pattern analyst specializing in behavioral chronology from email metadata. \
                Map communication rhythms per sender: typical active hours, response latency patterns, and working days. \
                Detect volume anomalies: sudden spikes (crisis events), prolonged silence (disengagement or absence), and gradual trends. \
                Measure response latency patterns: which senders get fast replies (priority), which get delayed (avoidance or low priority). \
                Identify burst patterns: rapid-fire exchanges indicating real-time collaboration or escalating conflict. \
                Flag out-of-pattern behavior: messages at unusual hours, weekend activity from weekday-only senders, or holiday communication. \
                Correlate timing with content: do volume spikes coincide with specific topics, deadlines, or external events? \
                Detect communication cadence changes: weekly check-ins that become daily, or regular updates that stop. \
                Output format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        case .securityExpert:
            expertInstructions = """
                You are a senior cybersecurity and data protection analyst specializing in email threat assessment. \
                Detect phishing indicators: urgency language, impersonation attempts, mismatched display names vs. addresses, suspicious links. \
                Identify PII exposure: Social Security numbers, credit card patterns, passwords, API keys, or credentials in plain text. \
                Flag data exfiltration patterns: large attachments to external domains, forwarding chains to personal addresses, BCC to unknown recipients. \
                Analyze sender authenticity: first-time senders with executive names, slight domain misspellings (typosquatting), free email domains for business communication. \
                Detect social engineering: pretexting, authority impersonation, artificial urgency, or unusual requests from known contacts. \
                Identify compliance risks: GDPR-regulated data sent without encryption, HIPAA-relevant health information, financial data in unprotected channels. \
                Rate each finding by risk severity (Critical/High/Medium/Low) with specific remediation recommendations. \
                Output format: [HIGH/MEDIUM/LOW] Finding — Evidence: (subject or sender).
                """
        }

        // Try structured generation — compact, parseable output
        guard isAvailable else {
            return AISessionFindings(
                findings: [AIFinding(finding: nlpData, evidence: "", relevance: .medium)],
                summary: "\(expertType): \(nlpData.prefix(100))",
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
                to: "Question: \(query)\n\nData:\n\(nlpData)",
                generating: AISessionFindings.self
            )
            return response.content
        } catch {
            return AISessionFindings(
                findings: [AIFinding(finding: nlpData, evidence: "", relevance: .medium)],
                summary: "\(expertType): \(nlpData.prefix(100))",
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
        emails: [MBOXParser.RawEmail],
        profile: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // ── Improvement 6: Adaptive expert count ──
        let sessionConfig = computeSessionCount(query: query, emails: emails, intent: intent)
        let allExperts = selectExperts(for: intent)
        let experts = Array(allExperts.prefix(sessionConfig.experts))
        let totalParallel = plan.subQueries.count + experts.count
        await onUpdate("*Layer 1: Deploying \(totalParallel) parallel AI sessions across \(emails.count) emails...*\n\n")

        // ── Layer 1: Parallel structured extraction ──
        var expertFindings: [(ExpertRole, AISessionFindings)] = []
        var subFindings: [(String, AISessionFindings)] = []

        await withTaskGroup(of: (String, Int?, ExpertRole?, AISessionFindings).self) { group in
            for expert in experts {
                group.addTask {
                    let findings = await runExpertStructured(role: expert, query: query, emails: emails)
                    return ("expert", nil, expert, findings)
                }
            }
            for (i, subQ) in plan.subQueries.enumerated() {
                let capturedSubQ = subQ
                group.addTask {
                    let findings = await executeSubQueryStructured(subQuery: capturedSubQ, emails: emails, profile: profile)
                    return ("map", i, nil, findings)
                }
            }

            var mapIndexed: [(Int, String, AISessionFindings)] = []
            for await (type, idx, role, findings) in group {
                if type == "expert", let r = role {
                    expertFindings.append((r, findings))
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
        let profileBudget = min(profile.count, contextCharBudget / 3)
        let availableBudget = contextCharBudget - profileBudget - 500 // reserve for instructions/query

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
        let intent = classifyIntentKeyword(subQuery)

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
            let truncatedContext = String(context.prefix(contextCharBudget))
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

    private static func serializeFindings(_ findings: [(source: String, finding: AIFinding, confidence: Int)]) -> String {
        guard !findings.isEmpty else { return "" }
        var text = "RANKED FINDINGS (\(findings.count) total, sorted by relevance):\n\n"
        for (i, entry) in findings.enumerated() {
            let relevanceIcon = entry.finding.relevance == .high ? "▲" : (entry.finding.relevance == .medium ? "●" : "▽")
            text += "[\(i+1)] \(relevanceIcon) \(entry.finding.finding)"
            if !entry.finding.evidence.isEmpty {
                text += " | Evidence: \(entry.finding.evidence)"
            }
            text += " (from: \(entry.source), confidence: \(entry.confidence)/5)\n"
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
        let profileTruncated = String(profile.prefix(contextCharBudget / 3))
        var reduceContext = profileTruncated + "\n\n" + findingsText

        let convoCtx = conversationContext()
        if !convoCtx.isEmpty {
            reduceContext = String(convoCtx.prefix(400)) + "\n" + reduceContext
        }
        reduceContext = String(reduceContext.prefix(contextCharBudget))

        let highCount = allFindings.filter { $0.finding.relevance == .high }.count
        let totalFindings = allFindings.count

        let instructions = "You are the AI brain of mailin. " +
            "You orchestrated a \(layerCount)-layer pipeline: \(totalParallel) parallel AI sessions analyzed \(emails.count) emails, " +
            "producing \(totalFindings) structured findings (\(highCount) high-relevance). " +
            "Findings are RANKED — ▲ = high relevance, ● = medium, ▽ = low. " +
            "Build your answer primarily from ▲ findings. Use ● for supporting context. Ignore ▽ unless unique. " +
            "Each finding includes evidence (email subjects/senders) — cite them with **bold**. " +
            "Synthesize into one coherent, evidence-rich answer. " +
            "Refer to emails by **Subject** and **sender**. " +
            "Synthesis goal: \(plan.synthesisGoal)"

        let tools = selectTools(for: intent, emails: emails)
        let session = tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)

        let prompt = "User question: \(query)\n\n\(reduceContext)"

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

        // For large archives, always include the archive profile (Apple AI sees the big picture)
        var context: String
        if emails.count >= multiSessionThreshold {
            context = profile + "\n\n"
            if !chunkEvidence.isEmpty { context += chunkEvidence + "\n" }
            let emailContext = buildBudgetedContext(
                intent: intent, query: query, relevant: relevant,
                allCount: emails.count, nlpStats: nlpStats
            )
            let remainingBudget = contextCharBudget - context.count
            context += String(emailContext.prefix(remainingBudget))
        } else {
            context = ""
            if !chunkEvidence.isEmpty { context += chunkEvidence + "\n" }
            context += buildBudgetedContext(
                intent: intent, query: query, relevant: relevant,
                allCount: emails.count, nlpStats: nlpStats
            )
        }

        let convoCtx = conversationContext()
        if !convoCtx.isEmpty {
            let convoTruncated = String(convoCtx.prefix(800))
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
        let budget = contextCharBudget

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
        let base = "You are the AI brain of mailin, a privacy-first Mac email app. All data is on-device. " +
            "You orchestrate on-device expert tools to build the best answer. " +
            "Always refer to emails by **Subject** and **sender name**, never by number. " +
            "Use your tools proactively — do not just answer from the provided context if a tool can give you better data. "

        switch intent {
        case .search:
            return base + "The user is searching for emails. " +
                "Use spotlightSearch for semantic/meaning-based search (Apple Intelligence powered). " +
                "Use searchEmails for keyword matching. Use lookupContact to identify senders. " +
                "Combine results from both search tools for comprehensive results."

        case .statistics:
            return base + "Answer with exact numbers. Use analyzeEmails to get sentiment, entities, " +
                "topics, classification, or priority breakdowns. The NLP data is deterministic ground truth. " +
                "Present clearly with percentages and comparisons."

        case .sentiment:
            return base + "Analyze emotional tone. Use analyzeEmails with sentiment type for ground truth data. " +
                "Use searchEmails to find specific examples of positive or negative emails. " +
                "Note patterns between contacts or topics."

        case .summary:
            return base + "Give a concise overview. Use spotlightSearch to find AI-generated summaries. " +
                "Use analyzeEmails for NLP breakdowns (topics, sentiment, categories). " +
                "Cover main themes, key contacts, patterns, sentiment. Keep to 3-4 paragraphs."

        case .security:
            return base + "Security analysis. Use analyzePhishing to scan for phishing, scams, and PII. " +
                "Use analyzeEmails for entity/classification analysis. " +
                "Use searchEmails to investigate suspicious senders further. " +
                "Explain each finding in plain language. Rate overall posture."

        case .triage:
            return base + "Priority triage. Use analyzeEmails with priority type for scoring. " +
                "Use checkCalendar to correlate with upcoming meetings. " +
                "Use searchEmails if you need more context on a priority email. " +
                "Group by urgency: Act Now, Today, This Week. Be actionable."

        case .thread:
            return base + "Thread narrative. Use getThread to fetch the full conversation. " +
                "Use spotlightSearch to find related discussions. " +
                "Use searchEmails for additional context. " +
                "Narrate chronologically. Highlight decisions, turning points, unresolved items."

        case .entity:
            return base + "Person/organization profile. " +
                "Use lookupContact to get their real identity, org, title from Contacts. " +
                "Use checkCalendar to find meetings with them. " +
                "Use spotlightSearch to find all their emails by meaning. " +
                "Cover: role, frequency, sentiment, topics, relationship."

        case .topicAnalysis:
            return base + "Topic analysis. Use analyzeEmails with topics type for NLP topic extraction. " +
                "Use searchEmails to find example emails for each topic. " +
                "Explain what each topic covers with evidence. Note connections."

        case .temporal:
            return base + "Temporal analysis. Use analyzeEmails for sentiment/topic trends. " +
                "Use dates from headers to anchor observations. " +
                "Analyze volume trends, topic shifts, sentiment changes over time."

        case .general:
            return base + "Answer thoroughly using all available tools: " +
                "spotlightSearch (AI semantic search), searchEmails (keyword search), " +
                "getThread (conversations), lookupContact (identity), checkCalendar (meetings), " +
                "analyzeEmails (NLP analysis), analyzePhishing (security scan). " +
                "Use multiple tools to build a comprehensive, evidence-based answer."
        }
    }
}

#endif
