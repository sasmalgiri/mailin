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
            let paragraphs = body.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 10 && !$0.hasPrefix(">") }

            if paragraphs.count <= 1 {
                tagger.string = body
                let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
                let score = Double(tag?.rawValue ?? "0") ?? 0
                return SentimentResult(email: email, score: score)
            }

            var totalScore = 0.0
            var totalWeight = 0.0
            for para in paragraphs {
                tagger.string = para
                let (tag, _) = tagger.tag(at: para.startIndex, unit: .paragraph, scheme: .sentimentScore)
                let score = Double(tag?.rawValue ?? "0") ?? 0
                let weight = Double(para.count)
                totalScore += score * weight
                totalWeight += weight
            }
            let avgScore = totalWeight > 0 ? totalScore / totalWeight : 0
            return SentimentResult(email: email, score: avgScore)
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
        var entityCounts: [String: (type: String, count: Int)] = [:]
        let noiseNames: Set<String> = ["re", "fw", "fwd", "http", "https", "www", "com", "org", "net", "cc", "bcc", "sent", "subject"]

        for email in emails {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let cleanBody = body.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
            let text = String(cleanBody.prefix(3000))
            tagger.string = text
            tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
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
                let entity = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if entity.count >= 2 && !noiseNames.contains(entity.lowercased()) {
                    let normalizedKey = "\(entity)|\(typeName)"
                    entityCounts[normalizedKey, default: (type: typeName, count: 0)].count += 1
                }
                return true
            }
        }

        return entityCounts
            .filter { $0.value.count >= 2 }
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
        var docFrequency: [String: Int] = [:]
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "was", "are", "were", "be", "been",
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
            "email", "mailto", "http", "https", "www", "com",
            "thanks", "thank", "regards", "dear", "hello", "hi", "hey",
            "best", "sincerely", "cheers", "reply", "forward", "forwarded",
            "wrote", "said", "original", "message", "mail", "subject",
            "attachment", "attached", "file", "click", "link", "view",
            "copy", "please", "let", "know", "get", "got", "like",
            "one", "two", "also", "new", "well", "way", "use", "make",
            "want", "see", "look", "need", "take", "come", "think",
            "good", "right", "going", "back", "much", "still", "made",
            "even", "thing", "many", "said", "give", "tell", "try",
        ]

        for email in emails {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let cleanBody = body.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
            let text = String(cleanBody.prefix(2000))
            tagger.string = text
            var wordsInDoc = Set<String>()
            let range = text.startIndex..<text.endIndex
            tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
                guard let tag = tag, tag == .noun || tag == .adjective else { return true }
                let word = String(text[tokenRange]).lowercased()
                if word.count >= 3 && !stopWords.contains(word) && word.range(of: #"^\d+$"#, options: .regularExpression) == nil {
                    wordCounts[word, default: 0] += 1
                    wordsInDoc.insert(word)
                }
                return true
            }
            for word in wordsInDoc {
                docFrequency[word, default: 0] += 1
            }
        }

        let emailCount = Double(max(emails.count, 1))
        return wordCounts
            .filter { $0.value >= 2 }
            .filter { docFrequency[$0.key, default: 0] < Int(emailCount * 0.7) }
            .map { (word: $0.key, count: $0.value, tfidf: Double($0.value) * log(emailCount / Double(docFrequency[$0.key, default: 1] + 1) + 1)) }
            .sorted { $0.tfidf > $1.tfidf }
            .prefix(limit)
            .map { (word: $0.word, count: $0.count) }
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
            var score = 0.0
            if !body.isEmpty {
                tagger.string = body
                let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
                score = Double(tag?.rawValue ?? "0") ?? 0
            }
            contactData[contact, default: (count: 0, sentimentSum: 0)].count += 1
            contactData[contact, default: (count: 0, sentimentSum: 0)].sentimentSum += score
        }

        return contactData
            .map { ContactInsight(address: $0.key, emailCount: $0.value.count, avgSentiment: $0.value.count > 0 ? $0.value.sentimentSum / Double($0.value.count) : 0) }
            .sorted { $0.emailCount > $1.emailCount }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Email Classification

    enum EmailCategory: String, CaseIterable {
        case personal = "Personal"
        case transactional = "Transactional"
        case newsletter = "Newsletter"
        case promotional = "Promotional"
        case automated = "Automated"
        case unknown = "Unknown"
    }

    static func classify(_ email: MBOXParser.RawEmail) -> EmailCategory {
        let from = (email.headers["From"] ?? "").lowercased()
        let subject = (email.headers["Subject"] ?? "").lowercased()
        let headers = email.headers
        let body = (bodyText(for: email) ?? "").lowercased()

        if headers["List-Unsubscribe"] != nil || headers["list-unsubscribe"] != nil {
            if subject.contains("order") || subject.contains("receipt") || subject.contains("invoice") || subject.contains("shipping") || subject.contains("confirm") || subject.contains("payment") || subject.contains("delivery") {
                return .transactional
            }
            if subject.contains("newsletter") || subject.contains("digest") || subject.contains("weekly") || subject.contains("monthly") {
                return .newsletter
            }
            if subject.contains("sale") || subject.contains("off") || subject.contains("deal") || subject.contains("discount") || subject.contains("promo") || subject.contains("offer") {
                return .promotional
            }
            return .newsletter
        }

        if from.contains("noreply") || from.contains("no-reply") || from.contains("donotreply") || from.contains("mailer-daemon") || from.contains("postmaster") {
            if subject.contains("confirm") || subject.contains("receipt") || subject.contains("order") || subject.contains("invoice") || subject.contains("shipping") || subject.contains("password") || subject.contains("verification") || subject.contains("account") {
                return .transactional
            }
            return .automated
        }

        if subject.contains("order") || subject.contains("receipt") || subject.contains("invoice") || subject.contains("payment") || subject.contains("shipping") || subject.contains("delivery") || subject.contains("confirm") {
            return .transactional
        }

        if body.contains("unsubscribe") || body.contains("opt out") || body.contains("email preferences") {
            return .newsletter
        }

        return .personal
    }

    static func classifyAll(_ emails: [MBOXParser.RawEmail]) -> [EmailCategory: Int] {
        var counts: [EmailCategory: Int] = [:]
        for email in emails {
            let cat = classify(email)
            counts[cat, default: 0] += 1
        }
        return counts
    }

    // MARK: - Phishing / Scam Detection

    struct PhishingFlag {
        let email: MBOXParser.RawEmail
        let reasons: [String]
        let riskLevel: RiskLevel

        enum RiskLevel: String {
            case low = "Low"
            case medium = "Medium"
            case high = "High"
        }
    }

    static func detectPhishing(in emails: [MBOXParser.RawEmail]) -> [PhishingFlag] {
        var flagged: [PhishingFlag] = []
        for email in emails {
            var reasons: [String] = []
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()
            let body = (bodyText(for: email) ?? "").lowercased()

            let urgentPhrases = ["urgent", "act now", "immediately", "suspended", "verify your account", "confirm your identity", "unusual activity", "security alert", "unauthorized"]
            for phrase in urgentPhrases where subject.contains(phrase) || body.contains(phrase) {
                reasons.append("Urgency language: \"\(phrase)\"")
            }

            let phishingPatterns = ["click here to verify", "enter your password", "update your payment", "confirm your details", "click the link below", "your account will be", "won a prize", "lottery", "inherit", "million dollars"]
            for pattern in phishingPatterns where body.contains(pattern) {
                reasons.append("Suspicious phrase: \"\(pattern)\"")
            }

            let fromDisplay = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let fromAddress = from.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) ?? from
            if !fromDisplay.isEmpty && !fromAddress.isEmpty {
                let displayDomain = fromDisplay.components(separatedBy: "@").last ?? ""
                let addressDomain = fromAddress.components(separatedBy: "@").last ?? ""
                if !displayDomain.isEmpty && !addressDomain.isEmpty && displayDomain != addressDomain && displayDomain.contains(".") {
                    reasons.append("Display name domain mismatch")
                }
            }

            if body.range(of: #"https?://[^\s]*@[^\s]+"#, options: .regularExpression) != nil {
                reasons.append("URL with @ symbol (potential redirect)")
            }

            if body.range(of: #"https?://\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil {
                reasons.append("URL with raw IP address")
            }

            guard !reasons.isEmpty else { continue }
            let level: PhishingFlag.RiskLevel = reasons.count >= 3 ? .high : reasons.count >= 2 ? .medium : .low
            flagged.append(PhishingFlag(email: email, reasons: reasons, riskLevel: level))
        }
        return flagged
    }

    // MARK: - Per-Email Summarization

    static func summarizeEmail(_ email: MBOXParser.RawEmail) -> String {
        guard let body = bodyText(for: email), !body.isEmpty else {
            return "No content to summarize."
        }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        let cleanBody = body.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")

        let paragraphs = cleanBody.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 10 }
        var totalScore = 0.0
        var totalWeight = 0.0
        for para in (paragraphs.isEmpty ? [cleanBody] : paragraphs) {
            tagger.string = para
            let (tag, _) = tagger.tag(at: para.startIndex, unit: .paragraph, scheme: .sentimentScore)
            let s = Double(tag?.rawValue ?? "0") ?? 0
            let w = Double(para.count)
            totalScore += s * w
            totalWeight += w
        }
        let sentiment = totalWeight > 0 ? totalScore / totalWeight : 0
        let tone = sentiment > 0.3 ? "positive" : sentiment < -0.3 ? "negative" : "neutral"

        let sentences = cleanBody.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 15 }

        let scored = sentences.enumerated().map { (index, sentence) -> (String, Double) in
            var score = 0.0
            if index < 3 { score += 3.0 - Double(index) }
            if sentence.count >= 30 && sentence.count <= 150 { score += 1.0 }
            if sentence.range(of: #"[A-Z][a-z]{2,}"#, options: .regularExpression) != nil { score += 0.5 }
            let lower = sentence.lowercased()
            let actionWords = ["need", "will", "can", "must", "should", "deadline", "meeting", "confirm", "update", "decide", "plan", "schedule"]
            if actionWords.contains(where: { lower.contains($0) }) { score += 1.0 }
            let greetings = ["dear", "hello", "hi ", "hey", "regards", "sincerely", "best wishes", "cheers"]
            if greetings.contains(where: { lower.hasPrefix($0) || lower.hasSuffix($0) }) { score -= 2.0 }
            return (sentence, score)
        }

        let bestSentences = scored.sorted { $0.1 > $1.1 }.prefix(4).map { $0.0 }
        let preview = bestSentences.isEmpty ? String(cleanBody.prefix(250)) : bestSentences.joined(separator: ". ") + "."

        let wordCount = cleanBody.split(separator: " ").count
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let category = classify(email).rawValue

        var summary = "From: \(from)\n"
        summary += "Category: \(category) | Tone: \(tone) (score: \(String(format: "%.2f", sentiment))) | \(wordCount) words\n\n"
        summary += preview
        if !email.attachments.isEmpty {
            summary += "\n\n\(email.attachments.count) attachment(s): \(email.attachments.map(\.filename).joined(separator: ", "))"
        }
        return summary
    }

    // MARK: - PII Detection (GDPR/Compliance)

    struct PIIFinding: Identifiable {
        let id = UUID()
        let type: PIIType
        let value: String
        let emailID: UUID
        let emailSubject: String
    }

    enum PIIType: String, CaseIterable {
        case emailAddress = "Email Address"
        case phoneNumber = "Phone Number"
        case ssnPattern = "SSN-like Pattern"
        case creditCard = "Credit Card Pattern"
        case ipAddress = "IP Address"
        case passportNumber = "Passport Number"
        case dateOfBirth = "Date of Birth"
        case driversLicense = "Driver's License"
        case iban = "IBAN"
    }

    static func detectPII(in emails: [MBOXParser.RawEmail]) -> [PIIFinding] {
        var findings: [PIIFinding] = []
        let patterns: [(PIIType, String)] = [
            (.emailAddress, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            (.phoneNumber, #"(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#),
            (.ssnPattern, #"\b\d{3}[-\s]\d{2}[-\s]\d{4}\b"#),
            (.creditCard, #"\b(?:\d{4}[-\s]?){3}\d{4}\b"#),
            (.ipAddress, #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#),
            // US passport: 1 letter + 8 digits, or 9 digits
            (.passportNumber, #"\b[A-Z]\d{8}\b|\b\d{9}\b"#),
            // DOB patterns: MM/DD/YYYY, DD-MM-YYYY, YYYY-MM-DD with context keywords
            (.dateOfBirth, #"(?i)(?:d\.?o\.?b\.?|date\s*of\s*birth|born|birthday)\s*:?\s*\d{1,2}[/\-\.]\d{1,2}[/\-\.]\d{2,4}"#),
            // US driver's license: varies by state, common pattern is 1 letter + 6-14 digits
            (.driversLicense, #"(?i)(?:driver'?s?\s*(?:license|lic|licence)|DL)\s*#?\s*:?\s*[A-Z]?\d{6,14}\b"#),
            // IBAN: 2 letter country + 2 check digits + up to 30 alphanumeric
            (.iban, #"\b[A-Z]{2}\d{2}\s?[\dA-Z]{4}\s?[\dA-Z]{4}\s?[\dA-Z]{4}(?:\s?[\dA-Z]{4}){0,4}\s?[\dA-Z]{0,4}\b"#),
        ]
        let compiledPatterns = patterns.compactMap { type, pat -> (PIIType, NSRegularExpression)? in
            guard let regex = try? NSRegularExpression(pattern: pat) else { return nil }
            return (type, regex)
        }

        for email in emails {
            let body = bodyText(for: email) ?? ""
            let subject = email.headers["Subject"] ?? "(No Subject)"
            let searchText = body + " " + (email.headers.values.joined(separator: " "))
            let nsText = searchText as NSString

            for (type, regex) in compiledPatterns {
                let matches = regex.matches(in: searchText, range: NSRange(location: 0, length: nsText.length))
                var seen = Set<String>()
                for match in matches.prefix(5) {
                    let value = nsText.substring(with: match.range)
                    if seen.insert(value).inserted {
                        findings.append(PIIFinding(type: type, value: value, emailID: email.id, emailSubject: subject))
                    }
                }
            }
        }
        return findings
    }

    static func piiSummary(in emails: [MBOXParser.RawEmail]) -> [PIIType: Int] {
        let findings = detectPII(in: emails)
        var counts: [PIIType: Int] = [:]
        for f in findings {
            counts[f.type, default: 0] += 1
        }
        return counts
    }

    static func redactPII(in text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[EMAIL REDACTED]"),
            (#"(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#, "[PHONE REDACTED]"),
            (#"\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b"#, "[SSN REDACTED]"),
            (#"\b(?:\d{4}[-\s]?){3}\d{4}\b"#, "[CARD REDACTED]"),
            (#"\b[A-Z]\d{8}\b"#, "[PASSPORT REDACTED]"),
            (#"\b[A-Z]{2}\d{2}\s?[\dA-Z]{4}\s?[\dA-Z]{4}\s?[\dA-Z]{4}(?:\s?[\dA-Z]{4}){0,4}\s?[\dA-Z]{0,4}\b"#, "[IBAN REDACTED]"),
        ]
        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: replacement)
            }
        }
        return result
    }

    // MARK: - Priority Scoring

    struct PriorityResult {
        let email: MBOXParser.RawEmail
        let score: Int
        let reasons: [String]

        var level: PriorityLevel {
            if score >= 5 { return .high }
            if score >= 3 { return .medium }
            return .low
        }

        enum PriorityLevel: String {
            case high = "High"
            case medium = "Medium"
            case low = "Low"
        }
    }

    static func scorePriority(_ email: MBOXParser.RawEmail, replyCountPerSender: [String: Int] = [:]) -> PriorityResult {
        var score = 0
        var reasons: [String] = []
        let subject = (email.headers["Subject"] ?? "").lowercased()
        let from = email.headers["From"] ?? ""
        let body = (bodyText(for: email) ?? "").lowercased()

        let urgentWords = ["urgent", "asap", "important", "critical", "deadline", "time-sensitive", "action required", "immediate"]
        for word in urgentWords where subject.contains(word) || body.prefix(300).contains(word) {
            score += 2
            reasons.append("Urgency: \"\(word)\"")
            break
        }

        let questionMarks = subject.filter { $0 == "?" }.count + body.prefix(500).filter { $0 == "?" }.count
        if questionMarks >= 2 {
            score += 1
            reasons.append("Contains questions")
        }

        let actionWords = ["please", "could you", "can you", "need you to", "requesting", "follow up", "waiting for"]
        for word in actionWords where body.prefix(500).contains(word) {
            score += 1
            reasons.append("Action requested")
            break
        }

        if email.inReplyTo != nil || email.references?.isEmpty == false {
            score += 1
            reasons.append("Part of thread")
        }

        let senderKey = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if let replyCount = replyCountPerSender[senderKey], replyCount >= 3 {
            score += 1
            reasons.append("Frequent contact")
        }

        if !email.attachments.isEmpty {
            score += 1
            reasons.append("Has attachments")
        }

        return PriorityResult(email: email, score: score, reasons: reasons)
    }

    static func scoreAllPriorities(_ emails: [MBOXParser.RawEmail], replyCountPerSender: [String: Int] = [:]) -> [PriorityResult] {
        emails.map { scorePriority($0, replyCountPerSender: replyCountPerSender) }
            .sorted { $0.score > $1.score }
    }

    // MARK: - Thread Summarization

    static func summarizeThread(_ emails: [MBOXParser.RawEmail]) -> String {
        guard !emails.isEmpty else { return "No emails in thread." }
        let sorted = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }

        let participants = Set(sorted.compactMap { $0.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) })
        let subject = sorted.first?.headers["Subject"] ?? "(No Subject)"

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var sentimentSum = 0.0
        var sentimentCount = 0
        var keySentences: [String] = []
        var actionItems: [String] = []

        let actionPatterns = ["please", "could you", "need to", "should", "must", "will you", "action:", "todo:", "deadline", "by end of", "follow up"]

        for email in sorted {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let cleanBody = body.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: "\n")
            guard !cleanBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let paragraphs = cleanBody.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 10 }
            for para in (paragraphs.isEmpty ? [cleanBody] : paragraphs) {
                tagger.string = para
                let (tag, _) = tagger.tag(at: para.startIndex, unit: .paragraph, scheme: .sentimentScore)
                sentimentSum += Double(tag?.rawValue ?? "0") ?? 0 * Double(para.count)
                sentimentCount += para.count
            }

            let sentences = cleanBody.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 20 }

            for sentence in sentences.prefix(2) {
                let lower = sentence.lowercased()
                let isBoilerplate = ["dear", "hello", "hi ", "regards", "sincerely", "best wishes", "cheers", "thanks"]
                    .contains(where: { lower.hasPrefix($0) || lower.hasSuffix($0) })
                if !isBoilerplate && keySentences.count < 5 {
                    keySentences.append(sentence)
                }
            }

            for sentence in sentences {
                let lower = sentence.lowercased()
                for pattern in actionPatterns where lower.contains(pattern) {
                    let isBoilerplate = lower.count < 10 || lower.hasPrefix("hi") || lower.hasPrefix("dear")
                    if !isBoilerplate && actionItems.count < 5 {
                        actionItems.append(sentence)
                    }
                    break
                }
            }
        }

        let avgSentiment = sentimentCount > 0 ? sentimentSum / Double(sentimentCount) : 0
        let tone = avgSentiment > 0.3 ? "positive" : avgSentiment < -0.3 ? "negative" : "neutral"

        var summary = "Thread: \(subject)\n"
        summary += "Messages: \(sorted.count) | Participants: \(participants.joined(separator: ", "))\n"
        summary += "Tone: \(tone)\n\n"

        if !keySentences.isEmpty {
            summary += "Key Points:\n"
            for (i, s) in keySentences.enumerated() {
                summary += "  \(i + 1). \(s)\n"
            }
        }

        if !actionItems.isEmpty {
            summary += "\nAction Items:\n"
            for (i, a) in actionItems.enumerated() {
                summary += "  \(i + 1). \(a)\n"
            }
        }

        return summary
    }

    // MARK: - Thread Sentiment Trend

    struct ThreadSentimentTrend {
        let subject: String
        let participants: [String]
        let points: [(date: Date, sender: String, sentiment: Double, snippet: String)]
        let overallTrend: String
    }

    static func threadSentimentTrend(_ emails: [MBOXParser.RawEmail]) -> ThreadSentimentTrend {
        let sorted = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }
        let participants = Array(Set(sorted.compactMap {
            $0.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces)
        }))
        let subject = sorted.first?.headers["Subject"] ?? "(No Subject)"

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var points: [(date: Date, sender: String, sentiment: Double, snippet: String)] = []

        for email in sorted {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let clean = body.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            tagger.string = clean
            let (tag, _) = tagger.tag(at: clean.startIndex, unit: .paragraph, scheme: .sentimentScore)
            let score = Double(tag?.rawValue ?? "0") ?? 0
            let date = MBOXParser.parseDate(email.headers["Date"]) ?? .distantPast
            let sender = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            let snippet = String(clean.prefix(80))

            points.append((date: date, sender: sender, sentiment: score, snippet: snippet))
        }

        let trend: String
        if points.count >= 2 {
            let firstHalf = points.prefix(points.count / 2).map(\.sentiment)
            let secondHalf = points.suffix(points.count / 2).map(\.sentiment)
            let avgFirst = firstHalf.isEmpty ? 0 : firstHalf.reduce(0, +) / Double(firstHalf.count)
            let avgSecond = secondHalf.isEmpty ? 0 : secondHalf.reduce(0, +) / Double(secondHalf.count)
            let diff = avgSecond - avgFirst
            if diff > 0.15 { trend = "improving" }
            else if diff < -0.15 { trend = "declining" }
            else { trend = "stable" }
        } else {
            trend = "insufficient data"
        }

        return ThreadSentimentTrend(subject: subject, participants: participants, points: points, overallTrend: trend)
    }

    // MARK: - Semantic Synonym Expansion (NLEmbedding)

    private static func expandWithSynonyms(_ terms: [String], maxPerTerm: Int = 3) -> [(term: String, weight: Double)] {
        var expanded: [(term: String, weight: Double)] = terms.map { ($0.lowercased(), 1.0) }

        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return expanded }

        for term in terms {
            let lower = term.lowercased()
            embedding.enumerateNeighbors(for: lower, maximumCount: maxPerTerm, distanceType: .cosine) { neighbor, distance in
                let similarity = 1.0 - distance
                if similarity > 0.55 && neighbor.count >= 3 && !neighbor.contains("_") {
                    expanded.append((neighbor, similarity * 0.6))
                }
                return true
            }
        }

        let manualSynonyms: [String: [String]] = [
            "meeting": ["conference", "call", "standup", "sync", "appointment", "calendar"],
            "money": ["payment", "invoice", "billing", "price", "cost", "budget", "salary"],
            "deadline": ["due", "timeline", "milestone", "sprint"],
            "problem": ["issue", "bug", "error", "broken", "crash", "fail"],
            "update": ["change", "release", "deploy", "patch", "version"],
            "job": ["position", "role", "hiring", "career", "opportunity", "interview"],
            "travel": ["flight", "hotel", "booking", "trip", "itinerary"],
            "project": ["initiative", "task", "milestone", "deliverable"],
            "shipping": ["delivery", "tracking", "order", "package", "shipment"],
            "security": ["password", "authentication", "login", "verification", "2fa"],
        ]

        for term in terms {
            if let synonyms = manualSynonyms[term.lowercased()] {
                for syn in synonyms {
                    if !expanded.contains(where: { $0.term == syn }) {
                        expanded.append((syn, 0.4))
                    }
                }
            }
        }

        var seen = Set<String>()
        return expanded.filter { seen.insert($0.term).inserted }
    }

    // MARK: - Natural Language Date Parsing

    struct DateRange {
        let start: Date
        let end: Date
        let label: String
    }

    static func parseDateRange(from query: String) -> DateRange? {
        let lower = query.lowercased()
        let calendar = Calendar.current
        let now = Date()

        if lower.contains("today") {
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateRange(start: start, end: end, label: "today")
        }
        if lower.contains("yesterday") {
            guard let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return nil }
            let end = calendar.startOfDay(for: now)
            return DateRange(start: start, end: end, label: "yesterday")
        }
        if lower.contains("last week") || lower.contains("past week") {
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return DateRange(start: start, end: now, label: "the last 7 days")
        }
        if lower.contains("last month") || lower.contains("past month") {
            guard let start = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return DateRange(start: start, end: now, label: "the last month")
        }
        if lower.contains("last year") || lower.contains("past year") {
            guard let start = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
            return DateRange(start: start, end: now, label: "the last year")
        }
        if lower.contains("this week") {
            let start = calendar.dateComponents([.calendar, .yearForWeekOfYear, .weekOfYear], from: now).date ?? now
            return DateRange(start: start, end: now, label: "this week")
        }
        if lower.contains("this month") {
            var comps = calendar.dateComponents([.year, .month], from: now)
            comps.day = 1
            let start = calendar.date(from: comps) ?? now
            return DateRange(start: start, end: now, label: "this month")
        }
        if lower.contains("this year") {
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = 1
            comps.day = 1
            let start = calendar.date(from: comps) ?? now
            return DateRange(start: start, end: now, label: "this year")
        }

        let lastNDays = try? NSRegularExpression(pattern: #"last\s+(\d+)\s+days?"#)
        if let match = lastNDays?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let daysRange = Range(match.range(at: 1), in: lower),
           let days = Int(lower[daysRange]) {
            guard let start = calendar.date(byAdding: .day, value: -days, to: now) else { return nil }
            return DateRange(start: start, end: now, label: "the last \(days) days")
        }

        let months = ["january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
                       "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
                       "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let hasYear = lower.range(of: #"\b20\d{2}\b"#, options: .regularExpression) != nil
        let ambiguousMonths: Set<String> = ["march", "mar", "may"]
        for (name, month) in months {
            guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\b"),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { continue }
            if ambiguousMonths.contains(name) && !hasYear {
                guard let matchRange = Range(match.range, in: lower) else { continue }
                let start = max(lower.startIndex, lower.index(matchRange.lowerBound, offsetBy: -15, limitedBy: lower.startIndex) ?? lower.startIndex)
                let end = min(lower.endIndex, lower.index(matchRange.upperBound, offsetBy: 15, limitedBy: lower.endIndex) ?? lower.endIndex)
                let vicinity = String(lower[start..<end])
                let dateSignals = ["email", "emails", "from", "in ", "during", "since", "show", "find", "search"]
                if !dateSignals.contains(where: { vicinity.contains($0) }) { continue }
            }
            if true {
                let yearPattern = try? NSRegularExpression(pattern: #"\b(20\d{2})\b"#)
                var year = calendar.component(.year, from: now)
                if let yearMatch = yearPattern?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                   let yearRange = Range(yearMatch.range(at: 1), in: lower),
                   let parsedYear = Int(lower[yearRange]) {
                    year = parsedYear
                }
                var startComps = DateComponents()
                startComps.year = year
                startComps.month = month
                startComps.day = 1
                guard let start = calendar.date(from: startComps),
                      let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
                return DateRange(start: start, end: end, label: "\(name.capitalized) \(year)")
            }
        }

        return nil
    }

    // MARK: - Fuzzy Name Matching

    static func fuzzyMatchContacts(name: String, in emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        let lowerName = name.lowercased()
        let nameParts = lowerName.split(separator: " ").map(String.init)

        return emails.filter { email in
            let from = (email.headers["From"] ?? "").lowercased()
            let to = (email.headers["To"] ?? "").lowercased()

            if from.contains(lowerName) || to.contains(lowerName) { return true }

            for part in nameParts where part.count >= 3 {
                if from.contains(part) || to.contains(part) { return true }
            }

            for field in [from, to] {
                let displayName = field.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let addr = field.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").components(separatedBy: "@").first ?? ""
                let fieldParts = displayName.split(separator: " ").map(String.init)

                for searchPart in nameParts where searchPart.count >= 3 {
                    for fieldPart in fieldParts where fieldPart.count >= 3 {
                        if levenshteinRatio(fieldPart, searchPart) > 0.7 { return true }
                    }
                    if levenshteinRatio(addr, searchPart) > 0.7 { return true }
                }
            }

            return false
        }
    }

    private static func levenshteinRatio(_ s1: String, _ s2: String) -> Double {
        let (a, b) = (Array(s1), Array(s2))
        let (m, n) = (a.count, b.count)
        if m == 0 && n == 0 { return 1.0 }
        if m == 0 || n == 0 { return 0.0 }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                curr[j] = a[i-1] == b[j-1] ? prev[j-1] : 1 + min(prev[j], curr[j-1], prev[j-1])
            }
            swap(&prev, &curr)
        }
        return 1.0 - Double(prev[n]) / Double(max(m, n))
    }

    // MARK: - Query Intent Detection

    enum QueryIntent {
        case count
        case timeQuery
        case findPerson
        case findContent
        case comparison
        case latest
        case general
    }

    static func detectIntent(_ query: String) -> QueryIntent {
        let lower = query.lowercased()
        if lower.contains("how many") || lower.contains("count") || lower.contains("total number") || lower.contains("how much") {
            return .count
        }
        if lower.contains("when") || lower.contains("what date") || lower.contains("what time") || lower.contains("last time") {
            return .timeQuery
        }
        if lower.contains("latest") || lower.contains("most recent") || lower.contains("newest") || lower.contains("last email") {
            return .latest
        }
        if lower.contains("compare") || lower.contains("difference") || lower.contains("versus") || lower.contains(" vs ") {
            return .comparison
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = query
        var hasName = false
        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, _ in
            if tag == .personalName || tag == .organizationName { hasName = true }
            return !hasName
        }
        if hasName && (lower.contains("from") || lower.contains("to") || lower.contains("by") || lower.contains("about")) {
            return .findPerson
        }

        return .general
    }

    // MARK: - Intelligent Query Search

    struct SearchResult {
        let email: MBOXParser.RawEmail
        let score: Double
        let matchContext: String
    }

    static func extractSearchTerms(from query: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let stopWords: Set<String> = [
            "what", "when", "where", "who", "whom", "which", "why", "how",
            "did", "does", "do", "is", "are", "was", "were", "will", "would",
            "can", "could", "should", "shall", "may", "might", "must",
            "the", "a", "an", "this", "that", "these", "those",
            "me", "my", "mine", "i", "we", "our", "you", "your", "its",
            "show", "tell", "give", "find", "get", "list", "display", "look",
            "email", "emails", "mail", "message", "messages", "inbox",
            "about", "from", "to", "with", "in", "on", "at", "by", "for",
            "any", "all", "some", "most", "much", "many", "more",
            "say", "said", "wrote", "write", "sent", "send", "receive", "received",
            "have", "has", "had", "been", "being", "be",
            "and", "or", "but", "not", "no", "if", "then", "so",
            "there", "here", "also", "just", "only", "very", "really",
            "please", "thanks", "thank", "hi", "hello",
            "it", "he", "she", "they", "them", "his", "her", "their",
            "up", "out", "off", "over", "down",
        ]

        var terms: [String] = []
        tagger.string = query
        let range = query.startIndex..<query.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
            let word = String(query[tokenRange])
            let lower = word.lowercased()
            if lower.count >= 2 && !stopWords.contains(lower) {
                terms.append(word)
            }
            return true
        }

        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = query
        nameTagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, tokenRange in
            if tag == .personalName || tag == .organizationName {
                let name = String(query[tokenRange])
                if !terms.contains(where: { $0.lowercased() == name.lowercased() }) {
                    terms.insert(name, at: 0)
                }
            }
            return true
        }

        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    static func searchEmails(terms: [String], in emails: [MBOXParser.RawEmail], limit: Int = 10) -> [SearchResult] {
        guard !terms.isEmpty else { return [] }
        let expandedTerms = expandWithSynonyms(terms)
        var results: [SearchResult] = []

        for email in emails {
            var score = 0.0
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()
            let to = (email.headers["To"] ?? "").lowercased()
            let body = (bodyText(for: email) ?? "").lowercased()

            var hitCount = 0
            for (term, weight) in expandedTerms {
                var termScore = 0.0
                if from.contains(term) { termScore += 5.0 * weight }
                if to.contains(term) { termScore += 4.0 * weight }
                if subject.contains(term) { termScore += 3.0 * weight }
                if body.contains(term) { termScore += 1.0 * weight }

                if termScore == 0 && weight >= 1.0 && term.count >= 4 {
                    let stem = String(term.prefix(term.count - 1))
                    if from.contains(stem) { termScore += 3.0 }
                    else if subject.contains(stem) { termScore += 2.0 }
                    else if body.contains(stem) { termScore += 0.5 }
                }

                if termScore > 0 { hitCount += 1 }
                score += termScore
            }

            if hitCount > 1 { score *= 1.0 + Double(hitCount - 1) * 0.3 }
            guard score > 0 else { continue }

            let snippet = createSnippet(
                body: bodyText(for: email) ?? "",
                terms: expandedTerms.map(\.term)
            )
            results.append(SearchResult(email: email, score: score, matchContext: snippet))
        }

        return results.sorted { $0.score > $1.score }
            .prefix(limit).map { $0 }
    }

    static func searchWithDateFilter(terms: [String], in emails: [MBOXParser.RawEmail], dateRange: DateRange?, limit: Int = 15) -> [SearchResult] {
        var filtered = emails
        if let range = dateRange {
            filtered = emails.filter { email in
                guard let dateStr = email.headers["Date"],
                      let date = MBOXParser.parseDate(dateStr) else { return false }
                return date >= range.start && date <= range.end
            }
        }
        if terms.isEmpty && dateRange != nil {
            return filtered.prefix(limit).map { email in
                SearchResult(email: email, score: 1.0, matchContext: createSnippet(body: bodyText(for: email) ?? "", terms: []))
            }
        }
        return searchEmails(terms: terms, in: filtered, limit: limit)
    }

    static func isEmailRelated(_ query: String, terms: [String], emails: [MBOXParser.RawEmail]) -> Bool {
        let lower = query.lowercased()
        let emailConcepts: Set<String> = [
            "email", "mail", "message", "inbox", "sent", "received", "reply",
            "forward", "attachment", "subject", "sender", "recipient",
            "wrote", "write", "send", "contact", "conversation", "thread",
            "archive", "unread", "read", "cc", "bcc",
        ]
        if emailConcepts.contains(where: { lower.contains($0) }) { return true }

        if parseDateRange(from: lower) != nil { return true }

        let lowerTerms = terms.map { $0.lowercased() }
        for term in lowerTerms {
            if emails.prefix(200).contains(where: {
                ($0.headers["From"] ?? "").lowercased().contains(term) ||
                ($0.headers["To"] ?? "").lowercased().contains(term) ||
                ($0.headers["Subject"] ?? "").lowercased().contains(term)
            }) { return true }
        }

        let expanded = expandWithSynonyms(terms)
        for (term, weight) in expanded where weight < 1.0 {
            if emails.prefix(100).contains(where: {
                ($0.headers["Subject"] ?? "").lowercased().contains(term) ||
                (bodyText(for: $0) ?? "").lowercased().contains(term)
            }) { return true }
        }

        return false
    }

    // MARK: - Answer Synthesis

    static func synthesizeAnswer(query: String, terms: [String], results: [SearchResult], allEmails: [MBOXParser.RawEmail], dateRange: DateRange?) -> String {
        let intent = detectIntent(query)
        let matchedEmails = results.map(\.email)
        let senderCount = Set(matchedEmails.map { $0.headers["From"] ?? "" }).count
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        let boilerplate: Set<String> = ["dear", "hello", "hi ", "hey", "regards", "sincerely", "best wishes", "cheers", "thanks for your", "thank you for", "kind regards", "best,"]

        var response = ""

        if let range = dateRange {
            response += "Showing results from \(range.label).\n\n"
        }

        switch intent {
        case .count:
            response += "Found \(results.count) email\(results.count == 1 ? "" : "s")"
            if senderCount > 1 { response += " from \(senderCount) sender\(senderCount == 1 ? "" : "s")" }
            if let range = dateRange { response += " in \(range.label)" }
            response += ".\n\n"
            let senderGroups = Dictionary(grouping: matchedEmails, by: { $0.headers["From"] ?? "Unknown" })
                .sorted { $0.value.count > $1.value.count }
            if senderGroups.count > 1 {
                response += "By sender:\n"
                for (sender, emails) in senderGroups.prefix(5) {
                    let name = sender.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? sender
                    response += "  \(name): \(emails.count)\n"
                }
                response += "\n"
            }
            appendEmailListing(to: &response, results: results, terms: terms, boilerplate: boilerplate, dateFmt: dateFmt, maxItems: 4)

        case .timeQuery:
            let dateResults = results.compactMap { r -> (SearchResult, Date)? in
                guard let d = r.email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return nil }
                return (r, d)
            }
            let lower = query.lowercased()
            let isEarliest = lower.contains("first") || lower.contains("oldest") || lower.contains("earliest")
            let sorted = isEarliest ? dateResults.sorted { $0.1 < $1.1 } : dateResults.sorted { $0.1 > $1.1 }
            if let first = sorted.first {
                let from = first.0.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                response += "\(isEarliest ? "Earliest" : "Most recent") match: \(dateFmt.string(from: first.1))\n"
                response += "From: \(from)\n"
                response += "Subject: \(first.0.email.headers["Subject"] ?? "(No Subject)")\n\n"
            }
            appendEmailListing(to: &response, results: results, terms: terms, boilerplate: boilerplate, dateFmt: dateFmt, maxItems: 5)

        case .latest:
            let dateResults = results.compactMap { r -> (SearchResult, Date)? in
                guard let d = r.email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return nil }
                return (r, d)
            }.sorted { $0.1 > $1.1 }
            if let latest = dateResults.first {
                let from = latest.0.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                response += "Most recent: \(dateFmt.string(from: latest.1)) from \(from)\n"
                response += "Subject: \(latest.0.email.headers["Subject"] ?? "(No Subject)")\n\n"
                let body = bodyText(for: latest.0.email) ?? ""
                let content = extractBestSentences(from: body, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, maxLength: 400)
                if !content.isEmpty { response += "\"\(content)\"\n\n" }
            }
            if dateResults.count > 1 {
                response += "+\(dateResults.count - 1) more match\(dateResults.count - 1 == 1 ? "" : "es"). "
                if let oldest = dateResults.last {
                    response += "Earliest: \(dateFmt.string(from: oldest.1)).\n"
                }
                response += "\n"
            }

        case .findPerson:
            let lowerTerms = terms.map { $0.lowercased() }
            let nameMatches = fuzzyMatchContacts(name: terms.first ?? "", in: allEmails)
            if !nameMatches.isEmpty && nameMatches.count > results.count {
                let uniqueSenders = Set(nameMatches.compactMap { $0.headers["From"] })
                response += "Found \(nameMatches.count) email\(nameMatches.count == 1 ? "" : "s") involving this contact"
                if uniqueSenders.count > 1 { response += " (\(uniqueSenders.count) address\(uniqueSenders.count == 1 ? "" : "es"))" }
                response += ".\n\n"
            } else {
                response += "Found \(results.count) email\(results.count == 1 ? "" : "s").\n\n"
            }
            appendEmailListing(to: &response, results: results, terms: lowerTerms, boilerplate: boilerplate, dateFmt: dateFmt, maxItems: 6)
            appendContactCrossRef(to: &response, results: results, allEmails: allEmails, dateFmt: dateFmt)

        case .findContent, .comparison, .general:
            response += "Found \(results.count) email\(results.count == 1 ? "" : "s")"
            if senderCount > 1 { response += " from \(senderCount) sender\(senderCount == 1 ? "" : "s")" }
            response += ".\n\n"
            appendEmailListing(to: &response, results: results, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, dateFmt: dateFmt, maxItems: 6)
            appendTimeline(to: &response, matchedEmails: matchedEmails, dateFmt: dateFmt)
            appendContactCrossRef(to: &response, results: results, allEmails: allEmails, dateFmt: dateFmt)
        }

        return response
    }

    private static func appendEmailListing(to response: inout String, results: [SearchResult], terms: [String], boilerplate: Set<String>, dateFmt: DateFormatter, maxItems: Int) {
        for result in results.prefix(maxItems) {
            let email = result.email
            let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            let date = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }
            let dateStr = date.map { dateFmt.string(from: $0) } ?? (email.headers["Date"] ?? "")

            let body = bodyText(for: email) ?? ""
            let content = extractBestSentences(from: body, terms: terms, boilerplate: boilerplate, maxLength: 300)

            response += "\(from) (\(dateStr)):\n"
            if let subject = email.headers["Subject"] {
                response += "Re: \(subject)\n"
            }
            if !content.isEmpty { response += "\"\(content)\"\n" }
            response += "\n"
        }

        if results.count > maxItems {
            response += "+\(results.count - maxItems) more email\(results.count - maxItems == 1 ? "" : "s") also match.\n\n"
        }
    }

    private static func appendTimeline(to response: inout String, matchedEmails: [MBOXParser.RawEmail], dateFmt: DateFormatter) {
        let dates = matchedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        if let first = dates.first, let last = dates.last, first != last {
            response += "Period: \(dateFmt.string(from: first)) — \(dateFmt.string(from: last))\n"
        }
        let replies = matchedEmails.filter { $0.inReplyTo != nil }.count
        if replies > 0 {
            response += "\(replies) of these are part of conversation threads.\n"
        }
    }

    private static func appendContactCrossRef(to response: inout String, results: [SearchResult], allEmails: [MBOXParser.RawEmail], dateFmt: DateFormatter) {
        let matchedEmails = results.map(\.email)
        let senderGroups = Dictionary(grouping: matchedEmails, by: { $0.headers["From"] ?? "" })
            .sorted { $0.value.count > $1.value.count }
        if let topGroup = senderGroups.first, topGroup.value.count >= 2 {
            let topName = topGroup.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? topGroup.key
            let addrPart = topGroup.key.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) ?? topGroup.key
            let totalFrom = allEmails.filter { ($0.headers["From"] ?? "").contains(addrPart) }.count
            let totalTo = allEmails.filter { ($0.headers["To"] ?? "").contains(addrPart) }.count
            if totalFrom > topGroup.value.count {
                response += "\n\(topName) has \(totalFrom) total emails in archive (\(totalTo) sent to them).\n"
            }
        }
    }

    private static func extractBestSentences(from body: String, terms: [String], boilerplate: Set<String>, maxLength: Int) -> String {
        let cleanBody = body.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: " ")

        let sentences = cleanBody.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { s in
                s.count > 15 && s.count < 300 &&
                !boilerplate.contains(where: { s.lowercased().hasPrefix($0) || s.lowercased().hasSuffix($0) })
            }

        var scored: [(String, Double)] = []
        let expandedTerms = expandWithSynonyms(terms, maxPerTerm: 2)
        for sentence in sentences {
            let lower = sentence.lowercased()
            var score = 0.0
            for (term, weight) in expandedTerms {
                if lower.contains(term) { score += 2.0 * weight }
            }
            if score > 0 { scored.append((sentence, score)) }
        }

        let topSentences = scored.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        if !topSentences.isEmpty {
            let combined = topSentences.joined(separator: ". ")
            return combined.count > maxLength ? String(combined.prefix(maxLength)) + "..." : combined
        }

        let fallback = cleanBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.count > maxLength ? String(fallback.prefix(maxLength)) + "..." : fallback
    }

    private static func createSnippet(body: String, terms: [String], maxLength: Int = 200) -> String {
        if body.isEmpty { return "" }
        let lower = body.lowercased()

        var bestStart = body.startIndex
        for term in terms {
            if let range = lower.range(of: term) {
                bestStart = range.lowerBound
                break
            }
        }

        let distance = body.distance(from: body.startIndex, to: bestStart)
        let offset = max(0, distance - 60)
        let startIdx = body.index(body.startIndex, offsetBy: offset)
        let remaining = body.distance(from: startIdx, to: body.endIndex)
        let endIdx = body.index(startIdx, offsetBy: min(maxLength, remaining))

        var snippet = String(body[startIdx..<endIdx])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if offset > 0 { snippet = "..." + snippet }
        if remaining > maxLength { snippet += "..." }
        return snippet
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
