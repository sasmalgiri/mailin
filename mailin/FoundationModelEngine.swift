import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
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
            You are an email archive analyst. The user has imported their email archive into \
            a privacy-focused Mac app called mailin. All processing happens on-device. \
            Analyze the provided email data and answer the user's question thoroughly. \
            Be specific — quote email content, name senders, cite dates. Use bullet points for lists. \
            If the question is not answerable from the email data, say so honestly. \
            If relevant emails were retrieved via search, focus your answer on those. \
            When the user references prior conversation, use context from the session history.
            """

        let session = LanguageModelSession(instructions: instructions)

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
        context += "\n"

        if let all = allEmails, contextEmails.count < all.count {
            context += "SHOWING \(contextEmails.count) MOST RELEVANT EMAILS (retrieved via semantic search from \(all.count) total):\n\n"
        }

        let snippetLength = allEmails != nil ? 800 : 500
        let sample = Array(contextEmails.prefix(50))
        for (i, email) in sample.enumerated() {
            let body = bodySnippet(for: email, maxLength: snippetLength)
            context += """
                --- Email \(i + 1) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(email.headers["Subject"] ?? "(No Subject)")
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
}

#endif
