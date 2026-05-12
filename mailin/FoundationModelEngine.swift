import Foundation

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
            let body = String(r.email.plainBody.prefix(300))
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
            output += "From: \(from) (\(date))\n\(String(email.plainBody.prefix(200)))\n\n"
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

        let indexResults = EmailSearchIndex.shared.hybridSearch(query: query, terms: searchTerms, limit: 30)
        if indexResults.count >= 3 {
            contextEmails = indexResults.map(\.email)
        } else if !searchTerms.isEmpty {
            let results = EmailNLPEngine.searchEmails(terms: searchTerms, in: emails, limit: 30)
            contextEmails = results.count >= 3 ? results.map(\.email) : Array(emails.prefix(50))
        } else {
            contextEmails = Array(emails.prefix(50))
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
        let prepared = prepareSession(query: query, emails: emails)
        let response = try await prepared.session.respond(to: prepared.prompt)
        return response.content
    }

    static func respondStreaming(to query: String, emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
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
        for (_, email) in retrievedEmails.prefix(20).enumerated() {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let body = bodySnippet(for: email, maxLength: 600)
            context += """
                --- \(subj) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(subj)
                Date: \(email.headers["Date"] ?? "")
                Body: \(body)

                """
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

        context += "EMAILS:\n\n"
        for (_, email) in retrievedEmails.prefix(20).enumerated() {
            let subj = email.headers["Subject"] ?? "(No Subject)"
            let body = bodySnippet(for: email, maxLength: 600)
            context += """
                --- \(subj) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(subj)
                Date: \(email.headers["Date"] ?? "")
                Body: \(body)

                """
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

    static func summarize(emails: [MBOXParser.RawEmail]) async throws -> String {
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

    // MARK: - Smart Triage / Priority Inbox

    static func triageEmails(_ emails: [MBOXParser.RawEmail], onUpdate: @MainActor @Sendable @escaping (String) -> Void) async throws -> String {
        guard !emails.isEmpty else {
            let msg = "No emails to triage. Import emails first."
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
        let phishingFlags = EmailNLPEngine.detectPhishing(in: emails)
        let piiSummary = EmailNLPEngine.piiSummary(in: emails)

        var context = "SECURITY ANALYSIS of \(emails.count) emails:\n\n"

        // Phishing findings
        if phishingFlags.isEmpty {
            context += "Phishing scan: No suspicious emails detected.\n\n"
        } else {
            context += "PHISHING ALERTS (\(phishingFlags.count) flagged):\n"
            for (i, flag) in phishingFlags.prefix(10).enumerated() {
                context += """
                    [\(i + 1)] Risk: \(flag.riskLevel.rawValue)
                    From: \(flag.email.headers["From"] ?? "Unknown")
                    Subject: \(flag.email.headers["Subject"] ?? "(No Subject)")
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
            You are a cybersecurity analyst in mailin, a privacy-first Mac app. \
            The NLP engine has scanned the email archive for phishing attempts and \
            personally identifiable information exposure. Explain the findings clearly.

            Rules:
            - ALWAYS refer to emails by their actual **Subject** line (in bold), never by number
            - Explain each risk in plain, non-technical language
            - For phishing: explain what makes each email suspicious and what could happen
            - For PII: explain the exposure risk and what someone could do with the data
            - Provide specific remediation steps for each finding
            - Use **bold** for risk levels, sender names, and action items
            - Rate overall security posture: Safe / Caution / At Risk
            - Be thorough but not alarmist — explain proportionate risk
            """

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Provide a security briefing based on these findings:\n\n\(context)"

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

        let snippetLength = allEmails != nil ? 800 : 500
        let sample = Array(contextEmails.prefix(50))
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
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength)) + "..."
    }

    // MARK: - Structured Generation (returns typed data instead of free text)

    static func triageStructured(_ emails: [MBOXParser.RawEmail]) async throws -> EmailTriageResult {
        guard !emails.isEmpty else {
            return EmailTriageResult(items: [], summary: "No emails to triage.")
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
        let phishingFlags = EmailNLPEngine.detectPhishing(in: emails)
        let piiSummary = EmailNLPEngine.piiSummary(in: emails)

        var context = "Security scan of \(emails.count) emails:\n\n"
        if phishingFlags.isEmpty {
            context += "Phishing: None detected\n"
        } else {
            context += "Phishing alerts (\(phishingFlags.count)):\n"
            for flag in phishingFlags.prefix(10) {
                context += "  Subject: \(flag.email.headers["Subject"] ?? "(No Subject)")\n"
                context += "  From: \(flag.email.headers["From"] ?? "Unknown")\n"
                context += "  Risk: \(flag.riskLevel.rawValue), Reasons: \(flag.reasons.joined(separator: "; "))\n\n"
            }
        }
        if !piiSummary.isEmpty {
            context += "PII detected:\n"
            for (type, count) in piiSummary { context += "  \(type.rawValue): \(count)\n" }
        }

        let instructions = "You are a cybersecurity analyst. Produce structured security findings."

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
}

#endif
