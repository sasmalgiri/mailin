import Foundation
import NaturalLanguage

struct EmailNLPEngine {

    // MARK: - Sentiment Analysis

    struct SentimentResult {
        let email: MBOXParser.RawEmail
        let score: Double
        var label: String {
            if score > 0.3 { return "Positive" }
            if score < -0.3 { return "Negative" }
            return "Neutral"
        }
    }

    static func analyzeSentiment(of emails: [MBOXParser.RawEmail]) -> [SentimentResult] {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        return emails.compactMap { email in
            guard let body = bodyText(for: email), !body.isEmpty else { return nil }
            tagger.string = body
            let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
            let score = Double(tag?.rawValue ?? "0") ?? 0
            return SentimentResult(email: email, score: score)
        }
    }

    static func averageSentiment(of emails: [MBOXParser.RawEmail]) -> (average: Double, label: String, positive: Int, negative: Int, neutral: Int) {
        let results = analyzeSentiment(of: emails)
        guard !results.isEmpty else { return (0, "Neutral", 0, 0, 0) }
        let avg = results.map(\.score).reduce(0, +) / Double(results.count)
        let pos = results.filter { $0.score > 0.3 }.count
        let neg = results.filter { $0.score < -0.3 }.count
        let neu = results.count - pos - neg
        let label: String
        if avg > 0.3 { label = "Positive" }
        else if avg < -0.3 { label = "Negative" }
        else { label = "Neutral" }
        return (avg, label, pos, neg, neu)
    }

    // MARK: - Named Entity Recognition

    struct EntityResult {
        let name: String
        let type: String
        let count: Int
    }

    static func extractEntities(from emails: [MBOXParser.RawEmail], limit: Int = 10) -> [EntityResult] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.setLanguage(.english, range: "".startIndex..<"".endIndex)
        var entityCounts: [String: (type: String, count: Int)] = [:]

        for email in emails {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let text = String(body.prefix(2000))
            tagger.string = text
            let range = text.startIndex..<text.endIndex
            tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, tokenRange in
                guard let tag = tag else { return true }
                let typeName: String
                switch tag {
                case .personalName: typeName = "Person"
                case .organizationName: typeName = "Organization"
                case .placeName: typeName = "Place"
                default: return true
                }
                let entity = String(text[tokenRange])
                if entity.count >= 2 {
                    let key = "\(entity)|\(typeName)"
                    entityCounts[key, default: (type: typeName, count: 0)].count += 1
                }
                return true
            }
        }

        return entityCounts
            .map { EntityResult(name: $0.key.components(separatedBy: "|").first ?? "", type: $0.value.type, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Language Detection

    struct LanguageResult {
        let language: String
        let count: Int
        let percentage: Double
    }

    static func detectLanguages(in emails: [MBOXParser.RawEmail]) -> [LanguageResult] {
        let recognizer = NLLanguageRecognizer()
        var langCounts: [String: Int] = [:]

        for email in emails {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            recognizer.reset()
            recognizer.processString(String(body.prefix(500)))
            if let lang = recognizer.dominantLanguage {
                let name = Locale.current.localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
                langCounts[name, default: 0] += 1
            }
        }

        let total = max(langCounts.values.reduce(0, +), 1)
        return langCounts
            .map { LanguageResult(language: $0.key, count: $0.value, percentage: Double($0.value) / Double(total) * 100) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Topic Extraction (keyword frequency)

    static func extractTopics(from emails: [MBOXParser.RawEmail], limit: Int = 10) -> [(word: String, count: Int)] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        var wordCounts: [String: Int] = [:]
        let stopWords: Set<String> = ["the", "a", "an", "is", "was", "are", "were", "be", "been",
                                       "have", "has", "had", "do", "does", "did", "will", "would",
                                       "could", "should", "may", "might", "shall", "can", "to", "of",
                                       "in", "for", "on", "with", "at", "by", "from", "as", "into",
                                       "through", "during", "before", "after", "above", "below",
                                       "between", "out", "off", "over", "under", "again", "further",
                                       "then", "once", "here", "there", "when", "where", "why", "how",
                                       "all", "both", "each", "few", "more", "most", "other", "some",
                                       "such", "no", "nor", "not", "only", "own", "same", "so", "than",
                                       "too", "very", "just", "don", "now", "it", "its", "this", "that",
                                       "these", "those", "i", "me", "my", "we", "our", "you", "your",
                                       "he", "him", "his", "she", "her", "they", "them", "their",
                                       "what", "which", "who", "whom", "if", "but", "or", "and",
                                       "because", "until", "while", "about", "up", "re", "sent",
                                       "email", "mailto", "http", "https", "www", "com"]

        for email in emails {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let text = String(body.prefix(1500))
            tagger.string = text
            let range = text.startIndex..<text.endIndex
            tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
                guard let tag = tag, tag == .noun || tag == .verb || tag == .adjective else { return true }
                let word = String(text[tokenRange]).lowercased()
                if word.count >= 3 && !stopWords.contains(word) {
                    wordCounts[word, default: 0] += 1
                }
                return true
            }
        }

        return wordCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }

    // MARK: - Busiest Contacts (by volume + sentiment)

    struct ContactInsight {
        let address: String
        let emailCount: Int
        let avgSentiment: Double
        var sentimentLabel: String {
            if avgSentiment > 0.3 { return "Positive" }
            if avgSentiment < -0.3 { return "Negative" }
            return "Neutral"
        }
    }

    static func contactInsights(from emails: [MBOXParser.RawEmail], limit: Int = 5) -> [ContactInsight] {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var contactData: [String: (count: Int, sentimentSum: Double)] = [:]

        for email in emails {
            let contact = email.headers["From"] ?? "Unknown"
            let body = bodyText(for: email) ?? ""
            tagger.string = body
            let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
            let score = Double(tag?.rawValue ?? "0") ?? 0
            contactData[contact, default: (count: 0, sentimentSum: 0)].count += 1
            contactData[contact, default: (count: 0, sentimentSum: 0)].sentimentSum += score
        }

        return contactData
            .map { ContactInsight(address: $0.key, emailCount: $0.value.count, avgSentiment: $0.value.count > 0 ? $0.value.sentimentSum / Double($0.value.count) : 0) }
            .sorted { $0.emailCount > $1.emailCount }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Helpers

    private static func bodyText(for email: MBOXParser.RawEmail) -> String? {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
