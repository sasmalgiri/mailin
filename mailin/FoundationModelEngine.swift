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

    static func respond(to query: String, emails: [MBOXParser.RawEmail]) async throws -> String {
        let emailContext = buildContext(from: emails)

        let instructions = """
            You are an email archive analyst. The user has imported their email archive into \
            a privacy-focused Mac app called mailin. All processing happens on-device. \
            Analyze the provided email data and answer the user's question. \
            Be concise and specific. Use bullet points for lists. \
            If you cannot determine something from the data, say so honestly.
            """

        let session = LanguageModelSession(instructions: instructions)

        let prompt = """
            Email archive data (\(emails.count) total emails):

            \(emailContext)

            User question: \(query)
            """

        let response = try await session.respond(to: prompt)
        return response.content
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

    private static func buildContext(from emails: [MBOXParser.RawEmail]) -> String {
        let sample = Array(emails.prefix(25))
        var context = ""

        for (i, email) in sample.enumerated() {
            let from = email.headers["From"] ?? "Unknown"
            let to = email.headers["To"] ?? "Unknown"
            let subject = email.headers["Subject"] ?? "(No Subject)"
            let date = email.headers["Date"] ?? ""
            let body = bodySnippet(for: email, maxLength: 300)

            context += """
                --- Email \(i + 1) ---
                From: \(from)
                To: \(to)
                Subject: \(subject)
                Date: \(date)
                Body: \(body)

                """
        }

        if emails.count > 25 {
            context += "\n[... and \(emails.count - 25) more emails not shown due to context limits]\n"
        }

        return context
    }

    private static func bodySnippet(for email: MBOXParser.RawEmail, maxLength: Int) -> String {
        let text: String
        if !email.plainBody.isEmpty {
            text = email.plainBody
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
