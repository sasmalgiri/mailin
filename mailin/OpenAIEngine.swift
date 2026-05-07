import Foundation

struct OpenAIEngine {

    enum Model: String, CaseIterable {
        case gpt4oMini = "gpt-4o-mini"
        case gpt4o = "gpt-4o"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .gpt4oMini: return "GPT-4o Mini (fast, affordable)"
            case .gpt4o: return "GPT-4o (best quality)"
            case .custom: return "Custom model"
            }
        }
    }

    static func respond(to query: String, emails: [MBOXParser.RawEmail], apiKey: String, model: String, endpoint: String, priorTurns: [(query: String, answer: String)] = []) async throws -> String {
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

        let context = buildContext(from: contextEmails, allEmails: emails)
        let isRAG = contextEmails.count < emails.count

        let systemPrompt = """
            You are an expert email analyst embedded in mailin, a privacy-focused email archive app. \
            You have deep access to the user's email archive and should answer like a knowledgeable \
            assistant who has thoroughly read every email.

            Guidelines:
            - Be conversational and insightful, like a trusted colleague who reviewed all the emails
            - Start with a direct answer to the question, then provide supporting details
            - Use **bold** for names and key terms, bullet points for lists
            - Quote specific email content when relevant (use > blockquotes)
            - Cite specific dates and senders — never be vague when data is available
            - When multiple emails are relevant, synthesize them into a coherent narrative
            - If you notice patterns, trends, or connections across emails, highlight them
            - If the data doesn't fully answer the question, say what you CAN determine and what's missing
            - Keep responses focused but thorough — aim for the quality of a well-written briefing
            - When the user references prior conversation, maintain continuity naturally
            """

        let userPrompt = """
            Email archive: \(emails.count) total emails\(isRAG ? " (\(contextEmails.count) most relevant shown below)" : ""):

            \(context)

            User question: \(query)
            """

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]

        for turn in priorTurns.suffix(4) {
            messages.append(["role": "user", "content": turn.query])
            let trimmedAnswer = String(turn.answer.prefix(2000))
            messages.append(["role": "assistant", "content": trimmedAnswer])
        }

        messages.append(["role": "user", "content": userPrompt])

        return try await callAPI(
            messages: messages,
            apiKey: apiKey,
            model: model,
            endpoint: endpoint
        )
    }

    static func respondStreaming(
        to query: String,
        emails: [MBOXParser.RawEmail],
        apiKey: String,
        model: String,
        endpoint: String,
        priorTurns: [(query: String, answer: String)] = [],
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
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

        let context = buildContext(from: contextEmails, allEmails: emails)
        let isRAG = contextEmails.count < emails.count

        let systemPrompt = """
            You are an expert email analyst embedded in mailin, a privacy-focused email archive app. \
            You have deep access to the user's email archive and should answer like a knowledgeable \
            assistant who has thoroughly read every email.

            Guidelines:
            - Be conversational and insightful, like a trusted colleague who reviewed all the emails
            - Start with a direct answer to the question, then provide supporting details
            - Use **bold** for names and key terms, bullet points for lists
            - Quote specific email content when relevant (use > blockquotes)
            - Cite specific dates and senders — never be vague when data is available
            - When multiple emails are relevant, synthesize them into a coherent narrative
            - If you notice patterns, trends, or connections across emails, highlight them
            - If the data doesn't fully answer the question, say what you CAN determine and what's missing
            - Keep responses focused but thorough — aim for the quality of a well-written briefing
            - When the user references prior conversation, maintain continuity naturally
            """

        let userPrompt = """
            Email archive: \(emails.count) total emails\(isRAG ? " (\(contextEmails.count) most relevant shown below)" : ""):

            \(context)

            User question: \(query)
            """

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]

        for turn in priorTurns.suffix(4) {
            messages.append(["role": "user", "content": turn.query])
            let trimmedAnswer = String(turn.answer.prefix(2000))
            messages.append(["role": "assistant", "content": trimmedAnswer])
        }

        messages.append(["role": "user", "content": userPrompt])

        return try await callStreamingAPI(
            messages: messages,
            apiKey: apiKey,
            model: model,
            endpoint: endpoint,
            onUpdate: onUpdate
        )
    }

    private static func callStreamingAPI(
        messages: [[String: String]],
        apiKey: String,
        model: String,
        endpoint: String,
        onUpdate: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let baseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)chat/completions" : "\(baseURL)/chat/completions"
        guard let url = URL(string: urlString) else {
            throw OpenAIError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 4096,
            "stream": true,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw OpenAIError.invalidAPIKey
        }

        if httpResponse.statusCode == 429 {
            throw OpenAIError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Collect error body from stream
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errorBody = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        var accumulated = ""
        var lineBuffer = ""

        for try await byte in bytes {
            let char = Character(UnicodeScalar(byte))
            if char == "\n" {
                let line = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                lineBuffer = ""

                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" {
                    break
                }

                guard let jsonData = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let delta = firstChoice["delta"] as? [String: Any],
                      let content = delta["content"] as? String else {
                    continue
                }

                accumulated += content
                await onUpdate(accumulated)
            } else {
                lineBuffer.append(char)
            }
        }

        if accumulated.isEmpty {
            throw OpenAIError.invalidResponse
        }

        return accumulated
    }

    private static func callAPI(messages: [[String: String]], apiKey: String, model: String, endpoint: String) async throws -> String {
        let baseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)chat/completions" : "\(baseURL)/chat/completions"
        guard let url = URL(string: urlString) else {
            throw OpenAIError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 4096,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw OpenAIError.invalidAPIKey
        }

        if httpResponse.statusCode == 429 {
            throw OpenAIError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.invalidResponse
        }

        return content
    }

    // MARK: - Context Builder

    private static func buildContext(from contextEmails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail]) -> String {
        var context = ""

        let sentCount = allEmails.filter { $0.messageType == "sent" }.count
        let recvCount = allEmails.filter { $0.messageType == "received" }.count
        let sentiment = EmailNLPEngine.averageSentiment(of: allEmails)
        let topics = EmailNLPEngine.extractTopics(from: allEmails, limit: 8)
        let classification = EmailNLPEngine.classifyAll(allEmails)
        let dates = allEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let totalSizeKB = allEmails.reduce(0) { $0 + $1.rawSource.utf8.count } / 1024

        context += "ARCHIVE STATS:\n"
        context += "Total: \(allEmails.count) emails (sent: \(sentCount), received: \(recvCount)), \(totalSizeKB) KB\n"
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

        if contextEmails.count < allEmails.count {
            context += "SHOWING \(contextEmails.count) MOST RELEVANT EMAILS (retrieved via semantic search from \(allEmails.count) total):\n\n"
        }

        for (i, email) in contextEmails.prefix(50).enumerated() {
            let body = bodySnippet(for: email, maxLength: 800)
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

    // MARK: - Errors

    enum OpenAIError: LocalizedError {
        case invalidAPIKey
        case invalidEndpoint
        case invalidResponse
        case rateLimited
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "Invalid API key. Check your key in Settings."
            case .invalidEndpoint: return "Invalid API endpoint URL."
            case .invalidResponse: return "Unexpected response from API."
            case .rateLimited: return "Rate limited. Wait a moment and try again."
            case .apiError(let code, let msg): return "API error (\(code)): \(msg)"
            }
        }
    }
}
