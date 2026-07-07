import Foundation
import NaturalLanguage

struct EmailNLPEngine {

    // MARK: - Sentiment Analysis

    struct SentimentResult {
        let email: MBOXParser.RawEmail
        let score: Double
        var label: String {
            if score > 0.4 { return "Positive" }
            if score < -0.4 { return "Negative" }
            return "Neutral"
        }
    }

    /// Detects structured professional/business emails by looking for common patterns
    /// such as bullet points, section headers, numbered lists, sign-offs, and business keywords.
    private static func isStructuredProfessionalEmail(_ body: String) -> Bool {
        let lines = body.components(separatedBy: .newlines)
        var signals = 0

        // Bullet points: lines starting with "- ", "• ", or "* "
        let bulletCount = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("* ")
        }.count
        if bulletCount >= 2 { signals += 1 }

        // Section headers: lines ending with ":"
        let headerCount = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasSuffix(":") && trimmed.count > 3 && trimmed.count < 80
        }.count
        if headerCount >= 1 { signals += 1 }

        // Numbered lists: lines starting with "1.", "2.", etc.
        let numberedCount = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }.count
        if numberedCount >= 2 { signals += 1 }

        let lower = body.lowercased()

        // Professional sign-offs
        let signOffs = ["regards", "best regards", "best,", "thanks,", "thank you,", "sincerely", "cheers,"]
        if signOffs.contains(where: { lower.contains($0) }) { signals += 1 }

        // Professional/business keywords
        let businessKeywords = ["meeting", "update", "progress", "status", "deadline", "deliverable",
                                "action item", "standup", "sprint", "blocker", "milestone", "agenda",
                                "follow up", "sync", "quarterly", "roadmap", "stakeholder"]
        let keywordHits = businessKeywords.filter { lower.contains($0) }.count
        if keywordHits >= 2 { signals += 1 }

        // Consider it professional if at least 2 signals are present
        return signals >= 2
    }

    static func analyzeSentiment(of emails: [MBOXParser.RawEmail]) -> [SentimentResult] {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        return emails.compactMap { email in
            guard let body = bodyText(for: email), !body.isEmpty else { return nil }
            let paragraphs = body.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 10 && !$0.hasPrefix(">") }

            var rawScore: Double
            if paragraphs.count <= 1 {
                tagger.string = body
                let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
                rawScore = Double(tag?.rawValue ?? "0") ?? 0
            } else {
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
                rawScore = totalWeight > 0 ? totalScore / totalWeight : 0
            }

            // Apply professional email bias: structured business emails get a +0.2 nudge
            // to counteract NLTagger scoring professional language (e.g. "blockers", "bugs",
            // "issues", "needs") as negative when it is actually neutral business terminology.
            if isStructuredProfessionalEmail(body) {
                rawScore += 0.2
                // Clamp to [-1, 1] range
                rawScore = min(1.0, max(-1.0, rawScore))
            }

            return SentimentResult(email: email, score: rawScore)
        }
    }

    static func averageSentiment(of emails: [MBOXParser.RawEmail]) -> (average: Double, label: String, positive: Int, negative: Int, neutral: Int) {
        let results = analyzeSentiment(of: emails)
        guard !results.isEmpty else { return (0, "Neutral", 0, 0, 0) }
        let avg = results.map(\.score).reduce(0, +) / Double(results.count)
        let pos = results.filter { $0.score > 0.4 }.count
        let neg = results.filter { $0.score < -0.4 }.count
        let neu = results.count - pos - neg
        let label: String
        if avg > 0.4 { label = "Positive" }
        else if avg < -0.4 { label = "Negative" }
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

    static func detectLanguagesHybrid(in emails: [MBOXParser.RawEmail]) async -> [LanguageResult] {
        let recognizer = NLLanguageRecognizer()
        var langCounts: [String: Int] = [:]
        let confidenceThreshold = 0.7

        // Phase 1: NLP pass — collect high-confidence results and low-confidence snippets
        var lowConfidenceSnippets: [(snippet: String, nlpFallback: String)] = []

        for email in emails {
            guard let body = bodyText(for: email), !body.isEmpty else { continue }
            let snippet = String(body.prefix(500))
            recognizer.reset()
            recognizer.processString(snippet)

            if let lang = recognizer.dominantLanguage {
                let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
                let topConfidence = hypotheses[lang] ?? 0

                if topConfidence >= confidenceThreshold {
                    let name = Locale.current.localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
                    langCounts[name, default: 0] += 1
                } else {
                    let fallback = Locale.current.localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
                    lowConfidenceSnippets.append((snippet: snippet, nlpFallback: fallback))
                }
            }
        }

        // Phase 2: Apple AI fallback for low-confidence detections — parallelism scales with count
        // Cap AI calls to prevent unbounded processing on huge archives
        let maxAIFallbacks: Int
        switch emails.count {
        case 0...500: maxAIFallbacks = lowConfidenceSnippets.count
        case 501...5000: maxAIFallbacks = min(lowConfidenceSnippets.count, 200)
        case 5001...20000: maxAIFallbacks = min(lowConfidenceSnippets.count, 400)
        default: maxAIFallbacks = min(lowConfidenceSnippets.count, 600)
        }
        // NLP-fallback the overflow beyond the cap
        for i in maxAIFallbacks..<lowConfidenceSnippets.count {
            langCounts[lowConfidenceSnippets[i].nlpFallback, default: 0] += 1
        }
        let cappedSnippets = Array(lowConfidenceSnippets.prefix(maxAIFallbacks))

        if !cappedSnippets.isEmpty {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let count = cappedSnippets.count
                let avgSnippetLen = cappedSnippets.reduce(0) { $0 + $1.snippet.count } / max(count, 1)
                let maxConcurrent: Int
                let concurrencyScale = avgSnippetLen < 200 ? 2 : (avgSnippetLen < 400 ? 1 : 0)
                switch count {
                case 1: maxConcurrent = 1
                case 2...5: maxConcurrent = min(2 + concurrencyScale, 4)
                case 6...15: maxConcurrent = min(3 + concurrencyScale, 5)
                case 16...40: maxConcurrent = min(4 + concurrencyScale, 7)
                default: maxConcurrent = min(5 + concurrencyScale, 10)
                }

                if count == 1 {
                    if let aiLang = await FoundationModelEngine.detectLanguage(text: cappedSnippets[0].snippet) {
                        langCounts[aiLang, default: 0] += 1
                    } else {
                        langCounts[cappedSnippets[0].nlpFallback, default: 0] += 1
                    }
                } else {
                    for groupStart in stride(from: 0, to: count, by: maxConcurrent) {
                        let groupEnd = min(groupStart + maxConcurrent, count)
                        let groupSlice = cappedSnippets[groupStart..<groupEnd]

                        let aiResults = await withTaskGroup(of: (Int, String?).self) { group in
                            for (i, item) in zip(groupStart..<groupEnd, groupSlice) {
                                group.addTask {
                                    let result = await FoundationModelEngine.detectLanguage(text: item.snippet)
                                    return (i, result)
                                }
                            }
                            var resolved: [Int: String?] = [:]
                            for await (idx, lang) in group {
                                resolved[idx] = lang
                            }
                            return resolved
                        }

                        for i in groupStart..<groupEnd {
                            if let aiLang = aiResults[i] ?? nil {
                                langCounts[aiLang, default: 0] += 1
                            } else {
                                langCounts[cappedSnippets[i].nlpFallback, default: 0] += 1
                            }
                        }
                    }
                }
            } else {
                for item in cappedSnippets {
                    langCounts[item.nlpFallback, default: 0] += 1
                }
            }
            #else
            for item in cappedSnippets {
                langCounts[item.nlpFallback, default: 0] += 1
            }
            #endif
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
            if avgSentiment > 0.4 { return "Positive" }
            if avgSentiment < -0.4 { return "Negative" }
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

        var scores: [EmailCategory: Double] = [:]

        // Header signals
        let hasListUnsub = headers["List-Unsubscribe"] != nil || headers["list-unsubscribe"] != nil
        let hasListId = headers["List-Id"] != nil || headers["list-id"] != nil
        let precedence = (headers["Precedence"] ?? headers["precedence"] ?? "").lowercased()
        let isNoReply = from.contains("noreply") || from.contains("no-reply") || from.contains("donotreply")
        let isDaemon = from.contains("mailer-daemon") || from.contains("postmaster") || from.contains("bounce")
        let hasAutoSubmitted = headers["Auto-Submitted"] != nil || headers["auto-submitted"] != nil
        let xMailer = (headers["X-Mailer"] ?? headers["x-mailer"] ?? "").lowercased()
        let isBulkMailer = xMailer.contains("mailchimp") || xMailer.contains("sendgrid") || xMailer.contains("constant contact") || xMailer.contains("campaign") || xMailer.contains("hubspot")

        // Transactional signals
        let transactionalSubjectWords = ["order", "receipt", "invoice", "payment", "shipping", "delivery", "confirm", "verification", "password", "account", "reset", "transaction", "purchase", "refund", "tracking"]
        let transactionalHits = transactionalSubjectWords.filter { subject.contains($0) }.count
        scores[.transactional, default: 0] += Double(transactionalHits) * 2.0
        if isNoReply && transactionalHits > 0 { scores[.transactional, default: 0] += 3.0 }

        // Newsletter signals
        if hasListUnsub { scores[.newsletter, default: 0] += 2.0 }
        if hasListId { scores[.newsletter, default: 0] += 2.0 }
        if precedence == "bulk" || precedence == "list" { scores[.newsletter, default: 0] += 2.0 }
        if isBulkMailer { scores[.newsletter, default: 0] += 3.0 }
        let newsletterWords = ["newsletter", "digest", "weekly", "monthly", "roundup", "bulletin", "issue #"]
        scores[.newsletter, default: 0] += Double(newsletterWords.filter { subject.contains($0) || body.prefix(500).contains($0) }.count) * 1.5
        if body.contains("unsubscribe") || body.contains("opt out") || body.contains("email preferences") || body.contains("manage subscriptions") {
            scores[.newsletter, default: 0] += 1.5
        }

        // Promotional signals
        let promoWords = ["sale", "% off", "deal", "discount", "promo", "offer", "limited time", "act now", "free shipping", "buy now", "save up to", "exclusive", "coupon", "clearance"]
        scores[.promotional, default: 0] += Double(promoWords.filter { subject.contains($0) || body.prefix(500).contains($0) }.count) * 1.5
        if hasListUnsub && scores[.promotional, default: 0] > 2 { scores[.promotional, default: 0] += 1.0 }

        // Automated signals
        if isDaemon { scores[.automated, default: 0] += 5.0 }
        if hasAutoSubmitted { scores[.automated, default: 0] += 4.0 }
        if isNoReply && transactionalHits == 0 { scores[.automated, default: 0] += 2.0 }
        let autoWords = ["auto-generated", "automatically generated", "do not reply", "this is an automated"]
        scores[.automated, default: 0] += Double(autoWords.filter { body.prefix(500).contains($0) }.count) * 2.0

        // Personal signals (negative evidence from others)
        let totalOtherSignals = scores.values.reduce(0, +)
        if totalOtherSignals < 1.5 {
            scores[.personal, default: 0] += 3.0
        }

        let best = scores.max { $0.value < $1.value }
        return best?.key ?? .personal
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
            var riskScore = 0
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()
            let body = (bodyText(for: email) ?? "").lowercased()
            let headers = email.headers
            let htmlBody = email.htmlBody.lowercased()

            // Urgency language
            let urgentPhrases = ["urgent", "act now", "immediately", "suspended", "verify your account", "confirm your identity", "unusual activity", "security alert", "unauthorized", "compromised", "locked", "expire", "limited time", "within 24 hours", "within 48 hours"]
            for phrase in urgentPhrases where subject.contains(phrase) || body.prefix(1000).contains(phrase) {
                reasons.append("Urgency language: \"\(phrase)\"")
                riskScore += 2
            }

            // Credential harvesting phrases
            let phishingPatterns = ["click here to verify", "enter your password", "update your payment", "confirm your details", "click the link below", "your account will be", "won a prize", "lottery", "inherit", "million dollars", "wire transfer", "western union", "send money", "bitcoin wallet", "cryptocurrency", "social security number", "bank account details"]
            for pattern in phishingPatterns where body.contains(pattern) {
                reasons.append("Suspicious phrase: \"\(pattern)\"")
                riskScore += 3
            }

            // Display name spoofing
            let fromDisplay = headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let fromAddress = from.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) ?? from
            if !fromDisplay.isEmpty && !fromAddress.isEmpty {
                let displayDomain = fromDisplay.components(separatedBy: "@").last ?? ""
                let addressDomain = fromAddress.components(separatedBy: "@").last ?? ""
                if !displayDomain.isEmpty && !addressDomain.isEmpty && displayDomain != addressDomain && displayDomain.contains(".") {
                    reasons.append("Display name domain mismatch")
                    riskScore += 3
                }
            }

            // Brand impersonation in display name
            let brandNames = ["paypal", "apple", "amazon", "microsoft", "google", "netflix", "bank of america", "wells fargo", "chase", "citibank", "facebook", "instagram", "linkedin", "dropbox", "docusign"]
            let displayLower = fromDisplay.lowercased()
            let addrDomain = fromAddress.components(separatedBy: "@").last ?? ""
            for brand in brandNames {
                if displayLower.contains(brand) && !addrDomain.contains(brand) {
                    reasons.append("Brand impersonation: display says \"\(brand)\" but sent from \(addrDomain)")
                    riskScore += 4
                    break
                }
            }

            // URL analysis
            if body.range(of: #"https?://[^\s]*@[^\s]+"#, options: .regularExpression) != nil {
                reasons.append("URL with @ symbol (potential redirect)")
                riskScore += 3
            }
            if body.range(of: #"https?://\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil {
                reasons.append("URL with raw IP address")
                riskScore += 3
            }

            // Shortened URLs
            let shorteners = ["bit.ly", "tinyurl", "goo.gl", "t.co", "ow.ly", "is.gd", "buff.ly", "rebrand.ly", "shorturl"]
            for shortener in shorteners where body.contains(shortener) || htmlBody.contains(shortener) {
                reasons.append("Shortened URL detected: \(shortener)")
                riskScore += 1
                break
            }

            // Mismatched link text vs href
            if let hrefMismatch = htmlBody.range(of: #"<a[^>]*href="https?://([^"]+)"[^>]*>[^<]*https?://([^<\s]+)"#, options: .regularExpression) {
                let match = String(htmlBody[hrefMismatch])
                if let hrefDomain = match.range(of: #"href="https?://([^/\"]+)"#, options: .regularExpression),
                   let textDomain = match.range(of: #">https?://([^<\s/]+)"#, options: .regularExpression) {
                    let h = String(htmlBody[hrefDomain])
                    let t = String(htmlBody[textDomain])
                    if h != t {
                        reasons.append("Link text shows different domain than actual URL")
                        riskScore += 4
                    }
                }
            }

            // SPF/DKIM authentication results
            let authResults = (headers["Authentication-Results"] ?? headers["authentication-results"] ?? "").lowercased()
            if authResults.contains("spf=fail") || authResults.contains("spf=softfail") {
                reasons.append("SPF authentication failed")
                riskScore += 2
            }
            if authResults.contains("dkim=fail") {
                reasons.append("DKIM authentication failed")
                riskScore += 2
            }

            // Reply-To mismatch
            if let replyTo = (headers["Reply-To"] ?? headers["reply-to"])?.lowercased() {
                let replyDomain = replyTo.components(separatedBy: "@").last?.components(separatedBy: ">").first ?? ""
                if !replyDomain.isEmpty && !addrDomain.isEmpty && replyDomain != addrDomain {
                    reasons.append("Reply-To domain (\(replyDomain)) differs from sender (\(addrDomain))")
                    riskScore += 2
                }
            }

            // v2.2.1: TLD risk scoring
            let tldRisk = assessTLDRisk(domain: addrDomain)
            if tldRisk.score > 0 {
                reasons.append(tldRisk.reason)
                riskScore += tldRisk.score
            }

            // v2.2.1: Encoded/obfuscated URL detection
            let encodedURLs = detectEncodedURLs(in: body + " " + htmlBody)
            for finding in encodedURLs {
                reasons.append(finding)
                riskScore += 2
            }

            // v2.2.1: Redirect chain detection in HTML
            let redirectChains = detectRedirectChains(in: htmlBody)
            for finding in redirectChains {
                reasons.append(finding)
                riskScore += 3
            }

            // v2.2.1: Full authentication results parsing
            let authDetail = parseAuthenticationResults(headers)
            if authDetail.spfResult == .fail || authDetail.spfResult == .softfail {
                if !reasons.contains(where: { $0.contains("SPF") }) {
                    reasons.append("SPF \(authDetail.spfResult.rawValue) for domain \(authDetail.spfDomain ?? "unknown")")
                    riskScore += authDetail.spfResult == .fail ? 3 : 2
                }
            }
            if authDetail.dkimResult == .fail {
                if !reasons.contains(where: { $0.contains("DKIM") }) {
                    reasons.append("DKIM fail (selector: \(authDetail.dkimSelector ?? "unknown"), domain: \(authDetail.dkimDomain ?? "unknown"))")
                    riskScore += 3
                }
            }
            if authDetail.dmarcResult == .fail {
                reasons.append("DMARC policy failure for \(authDetail.dmarcDomain ?? "unknown")")
                riskScore += 3
            }

            guard !reasons.isEmpty, riskScore >= 4 else { continue }
            let level: PhishingFlag.RiskLevel = riskScore >= 8 ? .high : .medium
            flagged.append(PhishingFlag(email: email, reasons: reasons, riskLevel: level))
        }
        return flagged
    }

    // MARK: - v2.2.1: Enhanced URL/Header Forensic Analysis

    enum AuthResult: String {
        case pass, fail, softfail, neutral, none, temperror, permerror, bestguesspass
        init(from string: String) {
            let lower = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            self = AuthResult(rawValue: lower) ?? .none
        }
    }

    struct EmailAuthenticationResult {
        var spfResult: AuthResult = .none
        var spfDomain: String?
        var dkimResult: AuthResult = .none
        var dkimDomain: String?
        var dkimSelector: String?
        var dmarcResult: AuthResult = .none
        var dmarcDomain: String?
        var hasARC: Bool = false

        var isFullyAuthenticated: Bool {
            spfResult == .pass && dkimResult == .pass && dmarcResult == .pass
        }

        var failureCount: Int {
            [spfResult, dkimResult, dmarcResult].filter { $0 == .fail || $0 == .softfail }.count
        }
    }

    static func parseAuthenticationResults(_ headers: [String: String]) -> EmailAuthenticationResult {
        var result = EmailAuthenticationResult()
        let authHeader = (headers["Authentication-Results"] ?? headers["authentication-results"] ?? "").lowercased()
        guard !authHeader.isEmpty else { return result }

        if let spfMatch = authHeader.range(of: #"spf=(\w+)"#, options: .regularExpression) {
            let value = String(authHeader[spfMatch]).replacingOccurrences(of: "spf=", with: "")
            result.spfResult = AuthResult(from: value)
        }
        if let spfDomainMatch = authHeader.range(of: #"smtp\.mailfrom=([^\s;]+)"#, options: .regularExpression) {
            result.spfDomain = String(authHeader[spfDomainMatch]).replacingOccurrences(of: "smtp.mailfrom=", with: "")
        }

        if let dkimMatch = authHeader.range(of: #"dkim=(\w+)"#, options: .regularExpression) {
            let value = String(authHeader[dkimMatch]).replacingOccurrences(of: "dkim=", with: "")
            result.dkimResult = AuthResult(from: value)
        }
        if let dkimDomainMatch = authHeader.range(of: #"header\.d=([^\s;]+)"#, options: .regularExpression) {
            result.dkimDomain = String(authHeader[dkimDomainMatch]).replacingOccurrences(of: "header.d=", with: "")
        }
        if let selectorMatch = authHeader.range(of: #"header\.s=([^\s;]+)"#, options: .regularExpression) {
            result.dkimSelector = String(authHeader[selectorMatch]).replacingOccurrences(of: "header.s=", with: "")
        }

        if let dmarcMatch = authHeader.range(of: #"dmarc=(\w+)"#, options: .regularExpression) {
            let value = String(authHeader[dmarcMatch]).replacingOccurrences(of: "dmarc=", with: "")
            result.dmarcResult = AuthResult(from: value)
        }
        if let dmarcDomainMatch = authHeader.range(of: #"header\.from=([^\s;]+)"#, options: .regularExpression) {
            result.dmarcDomain = String(authHeader[dmarcDomainMatch]).replacingOccurrences(of: "header.from=", with: "")
        }

        let arcHeader = headers["ARC-Authentication-Results"] ?? headers["arc-authentication-results"] ?? ""
        result.hasARC = !arcHeader.isEmpty

        return result
    }

    private static let suspiciousTLDs: [String: Int] = [
        "xyz": 3, "top": 3, "click": 4, "link": 3, "work": 2, "date": 3,
        "racing": 3, "download": 4, "stream": 3, "gdn": 3, "bid": 3,
        "loan": 3, "trade": 2, "win": 3, "review": 3, "science": 2,
        "party": 3, "faith": 3, "accountant": 3, "cricket": 3,
        "zip": 4, "mov": 4, "py": 2, "tk": 3, "ml": 3, "ga": 3, "cf": 3, "gq": 3,
        "buzz": 2, "icu": 3, "monster": 2, "rest": 2, "hair": 2, "quest": 2,
    ]

    private static func assessTLDRisk(domain: String) -> (score: Int, reason: String) {
        let parts = domain.components(separatedBy: ".")
        guard let tld = parts.last?.lowercased(), !tld.isEmpty else { return (0, "") }

        if let score = suspiciousTLDs[tld] {
            return (score, "Suspicious TLD: .\(tld) (commonly used in phishing)")
        }

        if parts.count > 3 {
            return (2, "Excessive subdomain depth (\(parts.count) levels): \(domain)")
        }

        return (0, "")
    }

    private static func detectEncodedURLs(in text: String) -> [String] {
        var findings: [String] = []

        if let _ = text.range(of: #"%[0-9a-fA-F]{2}.*%[0-9a-fA-F]{2}.*%[0-9a-fA-F]{2}"#, options: .regularExpression) {
            let decoded = text.removingPercentEncoding ?? text
            if decoded.contains("http") || decoded.contains("://") {
                findings.append("URL with heavy percent-encoding (potential obfuscation)")
            }
        }

        if text.range(of: #"&#x?[0-9a-fA-F]+;"#, options: .regularExpression) != nil &&
           text.range(of: #"https?://"#, options: .regularExpression) != nil {
            findings.append("HTML entity-encoded URL (potential obfuscation)")
        }

        if text.range(of: #"data:text/html"#, options: .regularExpression) != nil {
            findings.append("Data URI with HTML content (potential phishing payload)")
        }

        if text.range(of: #"javascript:"#, options: .caseInsensitive) != nil {
            findings.append("JavaScript URI detected")
        }

        return findings
    }

    private static func detectRedirectChains(in htmlBody: String) -> [String] {
        var findings: [String] = []

        if htmlBody.range(of: #"<meta\s+http-equiv\s*=\s*[\"']?refresh"#, options: [.regularExpression, .caseInsensitive]) != nil {
            findings.append("Meta refresh redirect detected (auto-redirect)")
        }

        let redirectDomains = ["redirect", "click.track", "trk.", "go.", "redir.", "forward.", "bounce."]
        let urlPattern = #"href="https?://([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let range = NSRange(htmlBody.startIndex..<htmlBody.endIndex, in: htmlBody)
            let matches = regex.matches(in: htmlBody, range: range)
            for match in matches {
                if let urlRange = Range(match.range(at: 1), in: htmlBody) {
                    let url = String(htmlBody[urlRange]).lowercased()
                    for redir in redirectDomains where url.contains(redir) {
                        findings.append("Multi-hop redirect URL detected (\(redir))")
                        break
                    }
                }
            }
        }

        return findings
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
        let tone = sentiment > 0.4 ? "positive" : sentiment < -0.4 ? "negative" : "neutral"

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

    // v2.2.2: PII Contextual Risk Scoring
    enum PIIRiskContext: String {
        case plainBody = "Plain Body"
        case quotedReply = "Quoted Reply"
        case header = "Header"
        case attachment = "Attachment"
        case signature = "Signature"
        case encryptedBody = "Encrypted"

        var riskMultiplier: Double {
            switch self {
            case .plainBody: return 1.0
            case .quotedReply: return 0.8
            case .header: return 0.6
            case .attachment: return 0.5
            case .signature: return 0.4
            case .encryptedBody: return 0.2
            }
        }
    }

    struct PIIFinding: Identifiable {
        let id = UUID()
        let type: PIIType
        let value: String
        let emailID: UUID
        let emailSubject: String
        var riskContext: PIIRiskContext = .plainBody

        var contextualRiskScore: Double {
            type.baseRisk * riskContext.riskMultiplier
        }
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

        var baseRisk: Double {
            switch self {
            case .ssnPattern: return 10.0
            case .creditCard: return 9.0
            case .passportNumber: return 8.0
            case .driversLicense: return 7.0
            case .iban: return 7.0
            case .dateOfBirth: return 5.0
            case .phoneNumber: return 4.0
            case .ipAddress: return 3.0
            case .emailAddress: return 2.0
            }
        }
    }

    static func detectPII(in emails: [MBOXParser.RawEmail]) -> [PIIFinding] {
        var findings: [PIIFinding] = []
        let patterns: [(PIIType, String)] = [
            (.emailAddress, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            (.phoneNumber, #"(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#),
            (.ssnPattern, #"\b(?!000|666|9\d{2})\d{3}[-\s](?!00)\d{2}[-\s](?!0000)\d{4}\b"#),
            (.creditCard, #"\b(?:\d{4}[-\s]?){3}\d{4}\b"#),
            (.ipAddress, #"\b(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\b"#),
            (.passportNumber, #"(?i)(?:passport)\s*#?\s*:?\s*[A-Z]\d{8}\b"#),
            (.dateOfBirth, #"(?i)(?:d\.?o\.?b\.?|date\s*of\s*birth|born|birthday)\s*:?\s*\d{1,2}[/\-\.]\d{1,2}[/\-\.]\d{2,4}"#),
            (.driversLicense, #"(?i)(?:driver'?s?\s*(?:license|lic|licence)|DL)\s*#?\s*:?\s*[A-Z]?\d{6,14}\b"#),
            (.iban, #"\b[A-Z]{2}\d{2}\s?[\dA-Z]{4}\s?[\dA-Z]{4}\s?[\dA-Z]{4}(?:\s?[\dA-Z]{4}){0,4}\s?[\dA-Z]{0,4}\b"#),
        ]
        let compiledPatterns = patterns.compactMap { type, pat -> (PIIType, NSRegularExpression)? in
            guard let regex = try? NSRegularExpression(pattern: pat) else { return nil }
            return (type, regex)
        }

        for email in emails {
            let subject = email.headers["Subject"] ?? "(No Subject)"

            // v2.2.2: Scan each section separately for contextual risk
            let sections: [(String, PIIRiskContext)] = determinePIISections(email)

            for (sectionText, context) in sections {
                let nsText = sectionText as NSString
                guard nsText.length > 0 else { continue }

                for (type, regex) in compiledPatterns {
                    let matches = regex.matches(in: sectionText, range: NSRange(location: 0, length: nsText.length))
                    var seen = Set<String>()
                    for match in matches.prefix(5) {
                        let value = nsText.substring(with: match.range)
                        if type == .creditCard {
                            let digits = value.filter(\.isNumber)
                            guard digits.count >= 13 && digits.count <= 19 && luhnCheck(digits) else { continue }
                        }
                        if type == .ipAddress {
                            let octets = value.split(separator: ".").compactMap { Int($0) }
                            guard octets.count == 4 && !octets.allSatisfy({ $0 == 0 }) else { continue }
                            if octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) { continue }
                            if octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31 { continue }
                        }
                        if seen.insert(value).inserted {
                            var finding = PIIFinding(type: type, value: value, emailID: email.id, emailSubject: subject)
                            finding.riskContext = context
                            findings.append(finding)
                        }
                    }
                }
            }

            // Also scan combined text with headers as fallback for coverage
            let headerText = email.headers.values.joined(separator: " ")
            let nsHeader = headerText as NSString
            for (type, regex) in compiledPatterns {
                let matches = regex.matches(in: headerText, range: NSRange(location: 0, length: nsHeader.length))
                for match in matches.prefix(3) {
                    let value = nsHeader.substring(with: match.range)
                    if !findings.contains(where: { $0.value == value && $0.emailID == email.id }) {
                        var finding = PIIFinding(type: type, value: value, emailID: email.id, emailSubject: subject)
                        finding.riskContext = .header
                        findings.append(finding)
                    }
                }
            }
        }
        return findings
    }

    private static func determinePIISections(_ email: MBOXParser.RawEmail) -> [(String, PIIRiskContext)] {
        var sections: [(String, PIIRiskContext)] = []
        let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
        let lines = body.components(separatedBy: .newlines)

        var bodyLines: [String] = []
        var quotedLines: [String] = []
        var signatureLines: [String] = []
        var inSignature = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inSignature && isSignatureMarker(trimmed) {
                inSignature = true
                signatureLines.append(trimmed)
            } else if inSignature {
                signatureLines.append(trimmed)
            } else if trimmed.hasPrefix(">") {
                quotedLines.append(String(trimmed.dropFirst()))
            } else {
                bodyLines.append(trimmed)
            }
        }

        if !bodyLines.isEmpty {
            sections.append((bodyLines.joined(separator: " "), .plainBody))
        }
        if !quotedLines.isEmpty {
            sections.append((quotedLines.joined(separator: " "), .quotedReply))
        }
        if !signatureLines.isEmpty {
            sections.append((signatureLines.joined(separator: " "), .signature))
        }

        return sections
    }

    private static func isSignatureMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower == "--" || lower == "-- " { return true }
        if lower.hasPrefix("sent from my") { return true }
        let signoffs = ["regards,", "best regards,", "sincerely,", "thanks,", "thank you,", "cheers,", "best,"]
        return signoffs.contains(where: { lower.hasPrefix($0) })
    }

    private static func luhnCheck(_ digits: String) -> Bool {
        var sum = 0
        let reversed = digits.reversed().map { Int(String($0)) ?? 0 }
        for (i, digit) in reversed.enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
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
                sentimentSum += (Double(tag?.rawValue ?? "0") ?? 0) * Double(para.count)
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
        let tone = avgSentiment > 0.4 ? "positive" : avgSentiment < -0.4 ? "negative" : "neutral"

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
            "meeting": ["conference", "call", "standup", "sync", "appointment", "calendar", "huddle", "catchup"],
            "money": ["payment", "invoice", "billing", "price", "cost", "budget", "salary", "revenue", "expense", "fee"],
            "deadline": ["due", "timeline", "milestone", "sprint", "cutoff", "eta", "target date"],
            "problem": ["issue", "bug", "error", "broken", "crash", "fail", "defect", "outage", "incident", "regression"],
            "update": ["change", "release", "deploy", "patch", "version", "rollout", "upgrade", "changelog"],
            "job": ["position", "role", "hiring", "career", "opportunity", "interview", "resume", "candidate", "recruit"],
            "travel": ["flight", "hotel", "booking", "trip", "itinerary", "airport", "visa", "accommodation"],
            "project": ["initiative", "task", "milestone", "deliverable", "workstream", "epic", "roadmap"],
            "shipping": ["delivery", "tracking", "order", "package", "shipment", "dispatch", "courier"],
            "security": ["password", "authentication", "login", "verification", "2fa", "breach", "vulnerability", "access"],
            "contract": ["agreement", "terms", "nda", "sow", "proposal", "amendment", "renewal"],
            "feedback": ["review", "comment", "suggestion", "critique", "evaluation", "assessment"],
            "approval": ["approve", "sign-off", "authorize", "greenlight", "consent", "permission"],
            "schedule": ["calendar", "agenda", "timetable", "slot", "availability", "recurring"],
            "team": ["group", "squad", "department", "division", "crew", "staff"],
            "customer": ["client", "account", "user", "subscriber", "buyer", "consumer"],
            "report": ["summary", "analysis", "dashboard", "metrics", "kpi", "stats"],
            "document": ["file", "attachment", "pdf", "spreadsheet", "deck", "presentation", "doc"],
            "urgent": ["asap", "critical", "blocker", "priority", "immediate", "time-sensitive"],
            "launch": ["release", "ship", "go-live", "deploy", "rollout", "announce"],
            "complaint": ["escalation", "dissatisfied", "unhappy", "dispute", "grievance"],
            "training": ["onboarding", "workshop", "tutorial", "course", "certification", "learning"],
            "legal": ["compliance", "regulation", "policy", "liability", "lawsuit", "subpoena"],
            "marketing": ["campaign", "promotion", "advertisement", "branding", "outreach", "newsletter"],
            "sales": ["deal", "pipeline", "quota", "prospect", "lead", "close", "revenue"],
            "support": ["help", "ticket", "helpdesk", "troubleshoot", "assist", "resolve"],
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

    private static let nicknameMap: [String: [String]] = {
        let pairs: [(String, [String])] = [
            ("michael", ["mike", "mikey", "mick"]),
            ("william", ["will", "bill", "billy", "willy", "liam"]),
            ("robert", ["rob", "bob", "bobby", "robbie"]),
            ("richard", ["rick", "rich", "dick", "ricky"]),
            ("james", ["jim", "jimmy", "jamie"]),
            ("john", ["jon", "johnny", "jack"]),
            ("jonathan", ["jon", "johnny", "nathan"]),
            ("joseph", ["joe", "joey"]),
            ("thomas", ["tom", "tommy"]),
            ("david", ["dave", "davey"]),
            ("daniel", ["dan", "danny"]),
            ("matthew", ["matt", "matty"]),
            ("christopher", ["chris", "topher"]),
            ("nicholas", ["nick", "nicky"]),
            ("anthony", ["tony"]),
            ("alexander", ["alex", "alec"]),
            ("benjamin", ["ben", "benny"]),
            ("samuel", ["sam", "sammy"]),
            ("andrew", ["andy", "drew"]),
            ("edward", ["ed", "eddie", "ted", "teddy"]),
            ("stephen", ["steve", "steven"]),
            ("steven", ["steve", "stephen"]),
            ("timothy", ["tim", "timmy"]),
            ("patrick", ["pat", "paddy"]),
            ("elizabeth", ["liz", "beth", "lizzy", "eliza", "betty"]),
            ("jennifer", ["jen", "jenny"]),
            ("katherine", ["kate", "kathy", "kat", "katie"]),
            ("catherine", ["kate", "cathy", "cat", "katie"]),
            ("margaret", ["maggie", "meg", "peggy"]),
            ("patricia", ["pat", "patty", "trish"]),
            ("jessica", ["jess", "jessie"]),
            ("rebecca", ["becca", "becky"]),
            ("victoria", ["vicky", "tori"]),
            ("stephanie", ["steph"]),
            ("alexandra", ["alex", "lexi"]),
            ("samantha", ["sam", "sammy"]),
            ("christina", ["chris", "tina"]),
            ("deborah", ["deb", "debbie"]),
            ("suzanne", ["sue", "suzy"]),
            ("susan", ["sue", "suzy"]),
            ("abigail", ["abby"]),
            ("madeline", ["maddie"]),
            ("nathaniel", ["nate", "nathan"]),
            ("zachary", ["zach", "zack"]),
            ("phillip", ["phil"]),
            ("gregory", ["greg"]),
            ("lawrence", ["larry"]),
            ("raymond", ["ray"]),
            ("gerald", ["gerry", "jerry"]),
            ("jeffrey", ["jeff"]),
            ("douglas", ["doug"]),
            ("kenneth", ["ken", "kenny"]),
            ("donald", ["don", "donnie"]),
            ("ronald", ["ron", "ronnie"]),
        ]
        var map: [String: [String]] = [:]
        for (formal, nicks) in pairs {
            map[formal, default: []].append(contentsOf: nicks)
            for nick in nicks {
                map[nick, default: []].append(formal)
                for otherNick in nicks where otherNick != nick {
                    map[nick, default: []].append(otherNick)
                }
            }
        }
        for key in map.keys {
            if let values = map[key] {
                map[key] = Array(Set(values))
            }
        }
        return map
    }()

    private static func nameVariants(_ name: String) -> Set<String> {
        let lower = name.lowercased()
        var variants: Set<String> = [lower]
        if let nicknames = nicknameMap[lower] {
            variants.formUnion(nicknames)
        }
        return variants
    }

    static func fuzzyMatchContacts(name: String, in emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        let lowerName = name.lowercased()
        let nameParts = lowerName.split(separator: " ").map(String.init)

        var allVariants: Set<String> = [lowerName]
        for part in nameParts {
            allVariants.formUnion(nameVariants(part))
        }

        return emails.filter { email in
            let from = (email.headers["From"] ?? "").lowercased()
            let to = (email.headers["To"] ?? "").lowercased()

            if from.contains(lowerName) || to.contains(lowerName) { return true }

            for variant in allVariants where variant.count >= 3 {
                if from.contains(variant) || to.contains(variant) { return true }
            }

            for field in [from, to] {
                let displayName = field.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let addr = field.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").components(separatedBy: "@").first ?? ""
                let fieldParts = displayName.split(separator: " ").map(String.init)

                for searchPart in nameParts where searchPart.count >= 3 {
                    let searchVariants = nameVariants(searchPart)
                    for fieldPart in fieldParts where fieldPart.count >= 3 {
                        if levenshteinRatio(fieldPart, searchPart) > 0.7 { return true }
                        for sv in searchVariants {
                            if levenshteinRatio(fieldPart, sv) > 0.7 { return true }
                        }
                    }
                    if levenshteinRatio(addr, searchPart) > 0.7 { return true }
                    for sv in searchVariants {
                        if levenshteinRatio(addr, sv) > 0.7 { return true }
                    }
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

    enum QueryIntent: CaseIterable {
        case count
        case timeQuery
        case findPerson
        case findContent
        case comparison
        case latest
        case summarize
        case sentiment
        case general
    }

    private static let intentExemplars: [QueryIntent: [String]] = [
        .count: [
            "how many emails", "count of messages", "total number", "how much mail",
            "number of emails from", "how many did I receive",
        ],
        .timeQuery: [
            "when did", "what date", "what time was", "last time they wrote",
            "first email from", "when was the earliest", "how long ago",
        ],
        .findPerson: [
            "emails from john", "what did sarah say", "messages to michael",
            "show me mail from", "find emails by", "correspondence with",
        ],
        .findContent: [
            "emails about budget", "find messages mentioning", "search for",
            "show me emails containing", "look for", "anything about",
        ],
        .comparison: [
            "compare emails from", "difference between", "versus", "how does X differ from Y",
            "contrast the messages", "side by side",
        ],
        .latest: [
            "most recent email", "latest message", "newest mail from",
            "last email about", "show me the latest",
        ],
        .summarize: [
            "summarize the conversation", "give me an overview", "what happened in this thread",
            "recap the discussion", "brief me on", "tldr", "what's the gist",
        ],
        .sentiment: [
            "what's the tone", "how positive", "mood of these emails",
            "are they angry", "sentiment of the conversation", "how does this person feel",
        ],
    ]

    private static let intentVectors: [QueryIntent: [[Double]]] = {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [:] }
        var result: [QueryIntent: [[Double]]] = [:]
        for (intent, exemplars) in intentExemplars {
            result[intent] = exemplars.compactMap { embedding.vector(for: $0) }
        }
        return result
    }()

    static func detectIntent(_ query: String) -> QueryIntent {
        let lower = query.lowercased()

        // Fast keyword checks for unambiguous queries
        if lower.contains("how many") || lower.contains("count") || lower.contains("total number") {
            return .count
        }
        if lower.contains("summarize") || lower.contains("summary") || lower.contains("overview") || lower.contains("recap") {
            return .summarize
        }

        // Semantic classification via sentence embeddings
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVec = embedding.vector(for: lower) else {
            return fallbackIntentDetection(lower)
        }

        let vectors = intentVectors
        guard !vectors.isEmpty else {
            return fallbackIntentDetection(lower)
        }

        var bestIntent: QueryIntent = .general
        var bestScore: Double = -1.0

        for (intent, exemplarVecs) in vectors {
            for vec in exemplarVecs {
                let sim = cosineSim(queryVec, vec)
                if sim > bestScore {
                    bestScore = sim
                    bestIntent = intent
                }
            }
        }

        // Also check for named entities to boost findPerson
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = query
        var hasName = false
        tagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, _ in
            if tag == .personalName || tag == .organizationName { hasName = true }
            return !hasName
        }
        if hasName && bestScore < 0.6 {
            return .findPerson
        }
        if hasName && bestIntent == .findContent {
            return .findPerson
        }

        return bestScore > 0.45 ? bestIntent : fallbackIntentDetection(lower)
    }

    private static func fallbackIntentDetection(_ lower: String) -> QueryIntent {
        if lower.contains("when") || lower.contains("what date") || lower.contains("what time") { return .timeQuery }
        if lower.contains("latest") || lower.contains("most recent") || lower.contains("newest") { return .latest }
        if lower.contains("compare") || lower.contains("difference") || lower.contains(" vs ") { return .comparison }
        if lower.contains("sentiment") || lower.contains("tone") || lower.contains("mood") { return .sentiment }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = lower
        var hasName = false
        tagger.enumerateTags(in: lower.startIndex..<lower.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, _ in
            if tag == .personalName || tag == .organizationName { hasName = true }
            return !hasName
        }
        if hasName { return .findPerson }
        return .general
    }

    private static func cosineSim(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, nA = 0.0, nB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            nA += a[i] * a[i]
            nB += b[i] * b[i]
        }
        let d = sqrt(nA) * sqrt(nB)
        return d > 0 ? dot / d : 0
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
        let n = Double(max(emails.count, 1))

        // Build document frequency for BM25-style IDF
        var docFreq: [String: Int] = [:]
        for (term, _) in expandedTerms {
            var count = 0
            for email in emails {
                let text = "\(email.headers["From"] ?? "") \(email.headers["To"] ?? "") \(email.headers["Subject"] ?? "") \(email.plainBody)"
                    .lowercased()
                if text.contains(term) { count += 1 }
            }
            docFreq[term] = count
        }

        let k1 = 1.2
        let b = 0.75
        let avgLen = emails.reduce(0.0) { $0 + Double($1.plainBody.split(separator: " ").count) } / n

        for email in emails {
            var score = 0.0
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()
            let to = (email.headers["To"] ?? "").lowercased()
            let body = (bodyText(for: email) ?? "").lowercased()
            let docLen = Double(body.split(separator: " ").count)

            var hitCount = 0
            for (term, weight) in expandedTerms {
                // Count term frequency in body
                var tf = 0
                var searchRange = body.startIndex..<body.endIndex
                while let range = body.range(of: term, range: searchRange) {
                    tf += 1
                    searchRange = range.upperBound..<body.endIndex
                    if tf >= 20 { break }
                }

                let df = Double(docFreq[term] ?? 1)
                let idf = log((n - df + 0.5) / (df + 0.5) + 1.0)
                let tfNorm = (Double(tf) * (k1 + 1)) / (Double(tf) + k1 * (1 - b + b * docLen / max(avgLen, 1)))
                var termScore = idf * tfNorm * weight

                // Field boosts
                if from.contains(term) { termScore += 4.0 * weight }
                if to.contains(term) { termScore += 3.0 * weight }
                if subject.contains(term) { termScore += 3.0 * weight }

                if termScore == 0 && weight >= 1.0 && term.count >= 4 {
                    let stem = String(term.prefix(term.count - 1))
                    if from.contains(stem) { termScore += 3.0 }
                    else if subject.contains(stem) { termScore += 2.0 }
                    else if body.contains(stem) { termScore += 0.5 }
                }

                if termScore > 0 { hitCount += 1 }
                score += termScore
            }

            if hitCount > 1 { score *= 1.0 + Double(hitCount - 1) * 0.4 }
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

        let displayName: (String?) -> String = { raw in
            guard let raw else { return "someone" }
            return raw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? raw
        }

        let allSubjects = Array(Set(matchedEmails.compactMap { $0.headers["Subject"] }))
        let topicPhrase: String = {
            let cleaned = allSubjects.map { $0.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") }
            let unique = Array(Set(cleaned))
            if unique.isEmpty { return terms.joined(separator: ", ") }
            if unique.count == 1 { return unique[0] }
            if unique.count <= 3 { return unique.joined(separator: ", ") }
            return "\(unique[0]), \(unique[1]), and \(unique.count - 2) other topic\(unique.count - 2 == 1 ? "" : "s")"
        }()

        let senderGroups = Dictionary(grouping: matchedEmails, by: { $0.headers["From"] ?? "Unknown" })
            .sorted { $0.value.count > $1.value.count }
        let topSenderNames = senderGroups.prefix(3).map { displayName($0.key) }

        var response = ""

        if let range = dateRange {
            response += "Looking at emails from \(range.label):\n\n"
        }

        switch intent {
        case .count:
            if results.count == 1 {
                let name = displayName(matchedEmails.first?.headers["From"])
                response += "There's **1 email** about this, from **\(name)**.\n\n"
            } else if senderCount == 1 {
                let name = displayName(matchedEmails.first?.headers["From"])
                response += "I found **\(results.count) emails** on this topic, all from **\(name)**.\n\n"
            } else {
                let nameList = topSenderNames.prefix(3).map { "**\($0)**" }
                let nameStr = nameList.count <= 2 ? nameList.joined(separator: " and ") : "\(nameList.dropLast().joined(separator: ", ")), and \(nameList.last ?? "")"
                response += "There are **\(results.count) emails** about this from \(senderCount) people, primarily \(nameStr).\n\n"
            }
            appendThematicSynthesis(to: &response, results: results, terms: terms, boilerplate: boilerplate, dateFmt: dateFmt, displayName: displayName)

        case .timeQuery:
            let dateResults = results.compactMap { r -> (SearchResult, Date)? in
                guard let d = r.email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return nil }
                return (r, d)
            }
            let lower = query.lowercased()
            let isEarliest = lower.contains("first") || lower.contains("oldest") || lower.contains("earliest")
            let sorted = isEarliest ? dateResults.sorted { $0.1 < $1.1 } : dateResults.sorted { $0.1 > $1.1 }
            if let first = sorted.first {
                let from = displayName(first.0.email.headers["From"])
                let subj = first.0.email.headers["Subject"] ?? "(No Subject)"
                response += "The \(isEarliest ? "earliest" : "most recent") match is from **\(from)** on **\(dateFmt.string(from: first.1))**, regarding \"\(subj)\".\n\n"
                let body = bodyText(for: first.0.email) ?? ""
                let content = extractBestSentences(from: body, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, maxLength: 300)
                if !content.isEmpty { response += "In that email, they wrote: \"\(content)\"\n\n" }
            }
            if sorted.count > 1 {
                let otherEnd = isEarliest ? sorted.last : sorted.dropFirst().last
                if let other = otherEnd {
                    response += "There are \(sorted.count - 1) other matching email\(sorted.count - 1 == 1 ? "" : "s"), with the \(isEarliest ? "most recent" : "earliest") from \(dateFmt.string(from: other.1)).\n\n"
                }
            }

        case .latest:
            let dateResults = results.compactMap { r -> (SearchResult, Date)? in
                guard let d = r.email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return nil }
                return (r, d)
            }.sorted { $0.1 > $1.1 }
            if let latest = dateResults.first {
                let from = displayName(latest.0.email.headers["From"])
                let subj = latest.0.email.headers["Subject"] ?? "(No Subject)"
                response += "The latest email on this is from **\(from)** on **\(dateFmt.string(from: latest.1))**, with the subject \"\(subj)\".\n\n"
                let body = bodyText(for: latest.0.email) ?? ""
                let content = extractBestSentences(from: body, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, maxLength: 400)
                if !content.isEmpty { response += "Here's what they said: \"\(content)\"\n\n" }
            }
            if dateResults.count > 1, let oldest = dateResults.last {
                let oldestName = displayName(oldest.0.email.headers["From"])
                response += "There \(dateResults.count - 1 == 1 ? "is" : "are") \(dateResults.count - 1) earlier email\(dateResults.count - 1 == 1 ? "" : "s") on this topic, going back to \(dateFmt.string(from: oldest.1)) from **\(oldestName)**.\n\n"
            }

        case .findPerson:
            let lowerTerms = terms.map { $0.lowercased() }
            let nameMatches = fuzzyMatchContacts(name: terms.first ?? "", in: allEmails)
            let personName = displayName(matchedEmails.first?.headers["From"])
            let emailCount = (!nameMatches.isEmpty && nameMatches.count > results.count) ? nameMatches.count : results.count

            if emailCount == 1 {
                response += "I found **1 email** involving **\(personName)**.\n\n"
            } else {
                response += "I found **\(emailCount) emails** involving **\(personName)**"
                if !nameMatches.isEmpty && nameMatches.count > results.count {
                    let uniqueSenders = Set(nameMatches.compactMap { $0.headers["From"] })
                    if uniqueSenders.count > 1 { response += " across \(uniqueSenders.count) different email addresses" }
                }
                response += ".\n\n"
            }

            if !allSubjects.isEmpty {
                let cleaned = allSubjects.map { $0.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") }
                let unique = Array(Set(cleaned))
                if unique.count == 1 {
                    response += "The conversation was about \"\(unique[0])\".\n\n"
                } else if unique.count <= 4 {
                    response += "Topics discussed include: \(unique.joined(separator: ", ")).\n\n"
                } else {
                    response += "They were involved in conversations about \(unique.prefix(3).joined(separator: ", ")), and \(unique.count - 3) other topic\(unique.count - 3 == 1 ? "" : "s").\n\n"
                }
            }

            // Synthesize what this person talked about, not just list emails
            let personSentiment = analyzeSentiment(of: matchedEmails)
            let toneWord = {
                let avg = personSentiment.map(\.score).reduce(0, +) / Double(max(personSentiment.count, 1))
                if avg > 0.2 { return "warm and positive" }
                if avg < -0.2 { return "somewhat critical or urgent" }
                return "professional and measured"
            }()
            response += "The overall tone of these exchanges is **\(toneWord)**.\n\n"

            appendThematicSynthesis(to: &response, results: results, terms: lowerTerms, boilerplate: boilerplate, dateFmt: dateFmt, displayName: displayName)
            appendContactCrossRef(to: &response, results: results, allEmails: allEmails, dateFmt: dateFmt)

        case .summarize:
            response += "Here's a synthesis of the **\(results.count) relevant emails**:\n\n"
            appendThematicSynthesis(to: &response, results: results, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, dateFmt: dateFmt, displayName: displayName)
            let sentiment = analyzeSentiment(of: matchedEmails)
            let avgSent = sentiment.map(\.score).reduce(0, +) / Double(max(sentiment.count, 1))
            let toneWord = avgSent > 0.2 ? "positive" : avgSent < -0.2 ? "tense" : "neutral"
            response += "The overall tone across these emails is **\(toneWord)**.\n\n"
            appendTimeline(to: &response, matchedEmails: matchedEmails, dateFmt: dateFmt)

        case .sentiment:
            let sentiment = analyzeSentiment(of: matchedEmails)
            let avg = sentiment.map(\.score).reduce(0, +) / Double(max(sentiment.count, 1))
            let toneWord = avg > 0.4 ? "quite positive" : avg > 0.1 ? "generally positive" : avg > -0.1 ? "neutral" : avg > -0.4 ? "somewhat negative" : "notably negative"
            response += "The tone across these **\(results.count) emails** is **\(toneWord)**.\n\n"
            let positive = sentiment.filter { $0.score > 0.4 }
            let negative = sentiment.filter { $0.score < -0.4 }
            if let topP = positive.sorted(by: { $0.score > $1.score }).first {
                response += "The most upbeat message is \"\(topP.email.headers["Subject"] ?? "(No Subject)")\" from **\(displayName(topP.email.headers["From"]))** — noticeably warm in tone.\n\n"
            }
            if let topN = negative.sorted(by: { $0.score < $1.score }).first {
                response += "The most critical message is \"\(topN.email.headers["Subject"] ?? "(No Subject)")\" from **\(displayName(topN.email.headers["From"]))** — carries a more serious or concerned tone.\n\n"
            }
            appendThematicSynthesis(to: &response, results: results, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, dateFmt: dateFmt, displayName: displayName)

        case .findContent, .comparison, .general:
            if results.count == 1 {
                let name = displayName(matchedEmails.first?.headers["From"])
                response += "I found **1 email** about this from **\(name)**.\n\n"
            } else {
                response += "Based on your emails, **\(topicPhrase)** comes up in **\(results.count) emails**"
                if senderCount > 1 {
                    let nameStr: String
                    if topSenderNames.count >= 3 {
                        nameStr = "**\(topSenderNames[0])**, **\(topSenderNames[1])**, and others"
                    } else {
                        nameStr = topSenderNames.map { "**\($0)**" }.joined(separator: " and ")
                    }
                    response += " from \(nameStr)"
                }
                response += ".\n\n"
            }
            appendThematicSynthesis(to: &response, results: results, terms: terms.map { $0.lowercased() }, boilerplate: boilerplate, dateFmt: dateFmt, displayName: displayName)
            appendTimeline(to: &response, matchedEmails: matchedEmails, dateFmt: dateFmt)
            appendContactCrossRef(to: &response, results: results, allEmails: allEmails, dateFmt: dateFmt)
        }

        if !response.hasSuffix("\n") { response += "\n" }
        if senderCount == 1, let topSender = topSenderNames.first {
            response += "\nYou can ask \"tell me more about \(topSender)\" for a full profile of this contact."
        } else if results.count > 6 {
            response += "\nFeel free to ask a more specific question to narrow things down, or ask about the sentiment or topics in these emails."
        }

        return response
    }

    // MARK: - Cross-Document Thematic Synthesis

    private static let themeTransitions = [
        "The main thread of conversation revolves around",
        "A significant exchange centers on",
        "Another key discussion involves",
        "There's also an important conversation about",
        "Meanwhile, a separate thread deals with",
        "Worth noting is the exchange regarding",
        "On a related front,",
        "Additionally, there's dialogue around",
    ]

    private static func appendThematicSynthesis(to response: inout String, results: [SearchResult], terms: [String], boilerplate: Set<String>, dateFmt: DateFormatter, displayName: (String?) -> String) {
        let emails = results.map(\.email)

        let threadGroups = Dictionary(grouping: emails) { email -> String in
            let subj = (email.headers["Subject"] ?? "").lowercased()
            return subj
                .replacingOccurrences(of: "re: ", with: "")
                .replacingOccurrences(of: "fwd: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.key.isEmpty }

        let sortedThreads = threadGroups.sorted { $0.value.count > $1.value.count }

        if sortedThreads.count >= 2 && emails.count > 3 {
            let allDates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            if let earliest = allDates.first, let latest = allDates.last, earliest != latest {
                response += "Across **\(emails.count) emails** from \(dateFmt.string(from: earliest)) to \(dateFmt.string(from: latest)), several themes emerge:\n\n"
            } else {
                response += "Across **\(emails.count) emails**, several themes emerge:\n\n"
            }

            for (i, (subject, threadEmails)) in sortedThreads.prefix(5).enumerated() {
                let sortedByDate = threadEmails.sorted {
                    (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
                    (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
                }
                let participants = Array(Set(sortedByDate.map { displayName($0.headers["From"]) }))
                let tagger = NLTagger(tagSchemes: [.sentimentScore])

                var bestContent = ""
                var bestScore = 0.0
                for email in sortedByDate {
                    let body = bodyText(for: email) ?? ""
                    let sentences = body.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { s in s.count > 20 && s.count < 300 && !boilerplate.contains(where: { s.lowercased().hasPrefix($0) }) }

                    for sentence in sentences.prefix(6) {
                        var score = 0.0
                        let lower = sentence.lowercased()
                        for term in terms where lower.contains(term) { score += 2.0 }
                        let actionWords = ["need", "will", "decide", "plan", "confirm", "agree", "deadline", "budget", "approve", "propose"]
                        if actionWords.contains(where: { lower.contains($0) }) { score += 1.5 }
                        if score > bestScore {
                            bestScore = score
                            bestContent = sentence
                        }
                    }
                }

                let allBody = sortedByDate.compactMap { bodyText(for: $0) }.joined(separator: " ")
                tagger.string = allBody
                let (tag, _) = tagger.tag(at: allBody.startIndex, unit: .paragraph, scheme: .sentimentScore)
                let sentimentScore = Double(tag?.rawValue ?? "0") ?? 0
                let tonePhrase: String
                if sentimentScore > 0.4 { tonePhrase = "with an upbeat, positive tone" }
                else if sentimentScore > 0.1 { tonePhrase = "in a generally constructive tone" }
                else if sentimentScore < -0.4 { tonePhrase = "with noticeable tension" }
                else if sentimentScore < -0.1 { tonePhrase = "with a somewhat cautious tone" }
                else { tonePhrase = "" }

                let displaySubject = subject.isEmpty ? "general matters" : subject
                let transition = themeTransitions[i % themeTransitions.count]
                let participantStr: String
                if participants.isEmpty {
                    participantStr = "unknown participants"
                } else if participants.count == 1 {
                    participantStr = "**\(participants[0])**"
                } else if participants.count == 2 {
                    participantStr = "**\(participants[0])** and **\(participants[1])**"
                } else {
                    participantStr = "**\(participants[0])**, **\(participants[1])**, and \(participants.count - 2) other\(participants.count - 2 == 1 ? "" : "s")"
                }

                response += "\(transition) **\(displaySubject)**"
                if threadEmails.count > 1 {
                    response += " (\(threadEmails.count) emails between \(participantStr))"
                } else {
                    response += " from \(participantStr)"
                }

                if let firstDate = sortedByDate.first.flatMap({ MBOXParser.parseDate($0.headers["Date"]) }),
                   let lastDate = sortedByDate.last.flatMap({ MBOXParser.parseDate($0.headers["Date"]) }),
                   firstDate != lastDate {
                    response += ", spanning \(dateFmt.string(from: firstDate)) to \(dateFmt.string(from: lastDate))"
                }
                response += ". "

                if !tonePhrase.isEmpty {
                    response += "The exchange reads \(tonePhrase). "
                }

                if !bestContent.isEmpty {
                    response += "A key point: \"\(bestContent)\""
                }
                response += "\n\n"
            }

            if sortedThreads.count > 5 {
                let remaining = sortedThreads.count - 5
                let extraSubjects = sortedThreads.dropFirst(5).prefix(3).map { $0.key }
                response += "There are **\(remaining) more thread\(remaining == 1 ? "" : "s")** touching on \(extraSubjects.joined(separator: ", "))\(remaining > 3 ? ", and more" : "").\n\n"
            }
        } else {
            appendEmailListing(to: &response, results: results, terms: terms, boilerplate: boilerplate, dateFmt: dateFmt, maxItems: 6)
        }
    }

    private static let narrativeOpeners = [
        { (from: String, dateStr: String, subj: String) -> String in
            "**\(from)** kicked things off on \(dateStr)" + (subj.isEmpty ? "" : " with \"\(subj)\"") },
        { (from: String, dateStr: String, subj: String) -> String in
            "The earliest relevant message comes from **\(from)** on \(dateStr)" + (subj.isEmpty ? "" : ", regarding \"\(subj)\"") },
        { (from: String, dateStr: String, subj: String) -> String in
            "On \(dateStr), **\(from)** wrote" + (subj.isEmpty ? "" : " about \"\(subj)\"") },
    ]

    private static let narrativeTransitions = [
        "Following up on that, ",
        "Shortly after, ",
        "Building on this, ",
        "In a related message, ",
        "Continuing the thread, ",
        "Later, ",
        "Adding to the conversation, ",
        "On a connected note, ",
        "Picking up the thread, ",
        "Further along, ",
        "Responding to that, ",
        "Circling back, ",
    ]

    private static func appendEmailListing(to response: inout String, results: [SearchResult], terms: [String], boilerplate: Set<String>, dateFmt: DateFormatter, maxItems: Int) {
        let count = results.count
        let showNarrative = count >= 1 && count <= 6

        if showNarrative {
            let items = results.prefix(maxItems)
            var usedTransitionIdx = 0

            for (index, result) in items.enumerated() {
                let email = result.email
                let rawFrom = email.headers["From"] ?? "Unknown"
                let from = rawFrom.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? rawFrom
                let date = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }
                let dateStr = date.map { dateFmt.string(from: $0) } ?? (email.headers["Date"] ?? "")

                let body = bodyText(for: email) ?? ""
                let content = extractBestSentences(from: body, terms: terms, boilerplate: boilerplate, maxLength: 250)

                let subj = email.headers["Subject"]?.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") ?? ""

                if index == 0 {
                    let openerIdx = abs(from.hashValue) % narrativeOpeners.count
                    let opener = narrativeOpeners[openerIdx](from, dateStr, subj)
                    if !content.isEmpty {
                        response += "\(opener): \"\(content)\"\n\n"
                    } else {
                        response += "\(opener).\n\n"
                    }
                } else {
                    let transition = narrativeTransitions[usedTransitionIdx % narrativeTransitions.count]
                    usedTransitionIdx += 1

                    if !content.isEmpty {
                        response += "\(transition)**\(from)** (\(dateStr))"
                        if !subj.isEmpty && index <= 3 { response += " re: \"\(subj)\"" }
                        response += " noted: \"\(content)\"\n\n"
                    } else {
                        response += "\(transition)**\(from)** weighed in on \(dateStr)"
                        if !subj.isEmpty { response += " regarding \"\(subj)\"" }
                        response += ".\n\n"
                    }
                }
            }

            if count > maxItems {
                let remaining = count - maxItems
                let remainingSenders = Array(Set(results.dropFirst(maxItems).map {
                    $0.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                }))
                if !remainingSenders.isEmpty && remainingSenders.count <= 3 {
                    response += "There are **\(remaining) more email\(remaining == 1 ? "" : "s")** on this topic from \(remainingSenders.joined(separator: " and ")).\n\n"
                } else {
                    response += "There are **\(remaining) more email\(remaining == 1 ? "" : "s")** continuing this discussion.\n\n"
                }
            }
        } else {
            response += "Here are the key messages:\n\n"
            for result in results.prefix(maxItems) {
                let email = result.email
                let rawFrom = email.headers["From"] ?? "Unknown"
                let from = rawFrom.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? rawFrom
                let date = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }
                let dateStr = date.map { dateFmt.string(from: $0) } ?? (email.headers["Date"] ?? "")

                let body = bodyText(for: email) ?? ""
                let content = extractBestSentences(from: body, terms: terms, boilerplate: boilerplate, maxLength: 200)

                response += "- **\(from)** (\(dateStr))"
                if let subject = email.headers["Subject"] {
                    response += " — \(subject)"
                }
                if !content.isEmpty { response += ": \"\(content)\"" }
                response += "\n"
            }

            if count > maxItems {
                response += "\n...plus \(count - maxItems) more email\(count - maxItems == 1 ? "" : "s") on this topic.\n"
            }
            response += "\n"
        }
    }

    private static func appendTimeline(to response: inout String, matchedEmails: [MBOXParser.RawEmail], dateFmt: DateFormatter) {
        let dates = matchedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        if let first = dates.first, let last = dates.last, first != last {
            response += "This conversation spanned from **\(dateFmt.string(from: first))** to **\(dateFmt.string(from: last))**.\n"
        }
        let replies = matchedEmails.filter { $0.inReplyTo != nil }.count
        if replies > 0 {
            let pct = Int(Double(replies) / Double(max(matchedEmails.count, 1)) * 100)
            response += "\(replies) of these (\(pct)%) are replies within conversation threads, indicating active back-and-forth discussion.\n"
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
                response += "\nFor context, **\(topName)** appears in \(totalFrom) emails total in your archive, and you've sent \(totalTo) emails to them.\n"
            }
        }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var results: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { results.append(s) }
            return true
        }
        return results
    }

    private static func truncateAtWordBoundary(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let truncated = String(text.prefix(maxLength))
        if let lastSpace = truncated.lastIndex(of: " "), truncated.distance(from: truncated.startIndex, to: lastSpace) > maxLength / 2 {
            return String(truncated[..<lastSpace]) + "..."
        }
        return truncated + "..."
    }

    private static func extractBestSentences(from body: String, terms: [String], boilerplate: Set<String>, maxLength: Int) -> String {
        let cleanBody = body.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: " ")

        let sentences = splitSentences(cleanBody).filter { s in
            s.count > 15 && s.count < 300 &&
            !boilerplate.contains(where: { s.lowercased().hasPrefix($0) || s.lowercased().hasSuffix($0) })
        }

        let expandedTerms = expandWithSynonyms(terms, maxPerTerm: 2)
        var scored: [(String, Double)] = []

        for (index, sentence) in sentences.enumerated() {
            let lower = sentence.lowercased()
            var score = 0.0

            var termHits = 0
            for (term, weight) in expandedTerms {
                if lower.contains(term) {
                    score += 2.0 * weight
                    termHits += 1
                }
            }
            if termHits > 1 { score *= 1.0 + Double(termHits - 1) * 0.3 }

            if index < 3 { score += 1.5 - Double(index) * 0.4 }

            let actionWords = ["need", "will", "decide", "plan", "confirm", "agree", "propose", "budget", "deadline", "approve", "schedule", "meeting", "require", "expect", "deliver", "complete"]
            if actionWords.contains(where: { lower.contains($0) }) { score += 1.0 }
            if lower.range(of: #"\d"#, options: .regularExpression) != nil { score += 0.5 }
            if lower.range(of: #"[A-Z][a-z]+"#, options: .regularExpression) != nil { score += 0.3 }
            if lower.contains("?") { score += 0.4 }

            if sentence.count >= 40 && sentence.count <= 200 { score += 0.5 }

            if score > 0 { scored.append((sentence, score)) }
        }

        let topSentences = scored.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        if !topSentences.isEmpty {
            let combined = topSentences.joined(separator: ". ")
            return truncateAtWordBoundary(combined, maxLength: maxLength)
        }

        let fallbackScored = sentences.enumerated().map { (idx, s) -> (String, Double) in
            var sc = 0.0
            if idx < 3 { sc += 1.0 }
            if s.count >= 40 && s.count <= 200 { sc += 0.5 }
            let lower = s.lowercased()
            let informativeWords = ["because", "however", "therefore", "important", "agree", "confirm", "actually", "specifically", "essentially"]
            if informativeWords.contains(where: { lower.contains($0) }) { sc += 1.0 }
            return (s, sc)
        }.sorted { $0.1 > $1.1 }

        if let best = fallbackScored.first, best.1 > 0 {
            return truncateAtWordBoundary(best.0, maxLength: maxLength)
        }

        let fallback = cleanBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncateAtWordBoundary(fallback, maxLength: maxLength)
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
        let rawOffset = max(0, distance - 60)

        var startIdx = body.index(body.startIndex, offsetBy: rawOffset)
        if rawOffset > 0 {
            if let spaceIdx = body[startIdx...].firstIndex(of: " ") {
                startIdx = body.index(after: spaceIdx)
            }
        }

        let remaining = body.distance(from: startIdx, to: body.endIndex)
        var endIdx = body.index(startIdx, offsetBy: min(maxLength, remaining))
        if remaining > maxLength {
            let tail = body[startIdx..<endIdx]
            if let lastSpace = tail.lastIndex(of: " "), tail.distance(from: tail.startIndex, to: lastSpace) > maxLength / 2 {
                endIdx = lastSpace
            }
        }

        var snippet = String(body[startIdx..<endIdx])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if rawOffset > 0 { snippet = "..." + snippet }
        if remaining > maxLength { snippet += "..." }
        return snippet
    }

    // MARK: - Near-Duplicate Detection

    struct NearDuplicateGroup: Identifiable {
        let id = UUID()
        let representative: MBOXParser.RawEmail
        let duplicates: [MBOXParser.RawEmail]
        let similarityScore: Double
    }

    static func findNearDuplicates(in emails: [MBOXParser.RawEmail], threshold: Double = 0.85) -> [NearDuplicateGroup] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }

        let capped = Array(emails.prefix(10_000))

        // Compute vectors for each email
        var vectors: [UUID: [Double]] = [:]
        for email in capped {
            let text = (email.headers["Subject"] ?? "") + " " + String(email.plainBody.prefix(500))
            if let vec = embedding.vector(for: text) {
                vectors[email.id] = vec
            }
        }

        // Group emails by sender for efficiency
        let senderGroups = Dictionary(grouping: capped) { email -> String in
            let from = (email.headers["From"] ?? "").lowercased()
            // Extract email address for grouping
            if let start = from.range(of: "<"), let end = from.range(of: ">") {
                return String(from[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return from.trimmingCharacters(in: .whitespaces)
        }

        var allGroups: [NearDuplicateGroup] = []

        for (_, groupEmails) in senderGroups {
            guard groupEmails.count >= 2 else { continue }

            var clustered = Set<UUID>()

            for i in 0..<groupEmails.count {
                let emailA = groupEmails[i]
                guard !clustered.contains(emailA.id),
                      let vecA = vectors[emailA.id] else { continue }

                var clusterMembers: [(email: MBOXParser.RawEmail, sim: Double)] = []

                for j in (i + 1)..<groupEmails.count {
                    let emailB = groupEmails[j]
                    guard !clustered.contains(emailB.id),
                          let vecB = vectors[emailB.id] else { continue }

                    let sim = cosineSim(vecA, vecB)
                    if sim >= threshold {
                        clusterMembers.append((email: emailB, sim: sim))
                    }
                }

                guard !clusterMembers.isEmpty else { continue }

                // All candidates including emailA
                var allInCluster = [emailA] + clusterMembers.map(\.email)

                // Sort by date to pick earliest as representative
                allInCluster.sort { a, b in
                    let dateA = MBOXParser.parseDate(a.headers["Date"]) ?? .distantFuture
                    let dateB = MBOXParser.parseDate(b.headers["Date"]) ?? .distantFuture
                    return dateA < dateB
                }

                let representative = allInCluster[0]
                let duplicates = Array(allInCluster.dropFirst())
                let avgSim = clusterMembers.map(\.sim).reduce(0, +) / Double(clusterMembers.count)

                for member in allInCluster {
                    clustered.insert(member.id)
                }

                allGroups.append(NearDuplicateGroup(
                    representative: representative,
                    duplicates: duplicates,
                    similarityScore: avgSim
                ))
            }
        }

        return allGroups.sorted { $0.duplicates.count > $1.duplicates.count }
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
