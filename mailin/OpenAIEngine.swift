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
            You are an email archive analyst. The user has imported their email archive into \
            a privacy-focused Mac app called mailin. Analyze the provided email data and \
            answer the user's question thoroughly. Be specific — quote email content, name \
            senders, cite dates. Use bullet points for lists. If the question is not answerable \
            from the email data, say so honestly. If relevant emails were retrieved via search, \
            focus your answer on those. When the user references prior conversation, use the \
            context from earlier messages to understand what they're referring to.
            """

        let userPrompt = """
            Email archive: \(emails.count) total emails\(isRAG ? " (\(contextEmails.count) most relevant shown below)" : ""):

            \(context)

            User question: \(query)
            """

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]

        for turn in priorTurns.suffix(4) {
            messages.append(["role": "user", "content": turn.query])
            let trimmedAnswer = String(turn.answer.prefix(500))
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
            "max_tokens": 2000,
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
        let dates = allEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()

        context += "ARCHIVE STATS:\n"
        context += "Total: \(allEmails.count) emails (sent: \(sentCount), received: \(recvCount))\n"
        if let first = dates.first, let last = dates.last {
            let f = DateFormatter()
            f.dateStyle = .medium
            context += "Period: \(f.string(from: first)) to \(f.string(from: last))\n"
        }
        context += "\n"

        if contextEmails.count < allEmails.count {
            context += "SHOWING \(contextEmails.count) MOST RELEVANT EMAILS:\n\n"
        }

        for (i, email) in contextEmails.prefix(50).enumerated() {
            let body = bodySnippet(for: email, maxLength: 600)
            context += """
                --- Email \(i + 1) ---
                From: \(email.headers["From"] ?? "Unknown")
                To: \(email.headers["To"] ?? "Unknown")
                Subject: \(email.headers["Subject"] ?? "(No Subject)")
                Date: \(email.headers["Date"] ?? "")
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
