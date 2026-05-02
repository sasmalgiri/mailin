import Foundation
import NaturalLanguage

final class EmailSearchIndex {
    static let shared = EmailSearchIndex()

    private var invertedIndex: [String: Set<UUID>] = [:]
    private var emailMap: [UUID: MBOXParser.RawEmail] = [:]
    private var emailVectors: [UUID: [Double]] = [:]
    private var isBuilt = false
    private let queue = DispatchQueue(label: "com.mailin.searchindex", qos: .userInitiated)

    var indexedCount: Int { emailMap.count }

    // MARK: - Build Index

    func build(from emails: [MBOXParser.RawEmail]) {
        queue.sync {
            invertedIndex.removeAll()
            emailMap.removeAll()
            emailVectors.removeAll()

            for email in emails {
                emailMap[email.id] = email

                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let body = bodyText(for: email).lowercased()

                let allText = "\(from) \(to) \(subject) \(body)"
                let tokens = tokenize(allText)

                for token in tokens {
                    invertedIndex[token, default: []].insert(email.id)
                }
            }

            buildVectors(for: emails)
            isBuilt = true
        }
    }

    func buildAsync(from emails: [MBOXParser.RawEmail], completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.invertedIndex.removeAll()
            self?.emailMap.removeAll()
            self?.emailVectors.removeAll()

            for email in emails {
                self?.emailMap[email.id] = email

                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let body = self?.bodyText(for: email).lowercased() ?? ""

                let allText = "\(from) \(to) \(subject) \(body)"
                let tokens = self?.tokenize(allText) ?? []

                for token in tokens {
                    self?.invertedIndex[token, default: []].insert(email.id)
                }
            }

            self?.buildVectors(for: emails)
            self?.isBuilt = true

            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - Keyword Search (Instant via Inverted Index)

    func search(terms: [String], limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt, !terms.isEmpty else { return [] }

        var scores: [UUID: Double] = [:]
        let lowerTerms = terms.map { $0.lowercased() }

        return queue.sync {
            for term in lowerTerms {
                let matchingIDs: Set<UUID>
                if let exact = invertedIndex[term] {
                    matchingIDs = exact
                } else {
                    var partial = Set<UUID>()
                    if term.count >= 4 {
                        let stem = String(term.prefix(term.count - 1))
                        for (key, ids) in invertedIndex where key.hasPrefix(stem) {
                            partial.formUnion(ids)
                        }
                    }
                    matchingIDs = partial
                }

                for id in matchingIDs {
                    guard let email = emailMap[id] else { continue }
                    var termScore = 0.0
                    let from = (email.headers["From"] ?? "").lowercased()
                    let to = (email.headers["To"] ?? "").lowercased()
                    let subject = (email.headers["Subject"] ?? "").lowercased()

                    if from.contains(term) { termScore += 5.0 }
                    if to.contains(term) { termScore += 4.0 }
                    if subject.contains(term) { termScore += 3.0 }
                    if termScore == 0 { termScore = 1.0 }

                    scores[id, default: 0] += termScore
                }
            }

            let multiTermBonus = lowerTerms.count > 1
            if multiTermBonus {
                for (id, _) in scores {
                    var hitCount = 0
                    for term in lowerTerms {
                        if invertedIndex[term]?.contains(id) == true { hitCount += 1 }
                    }
                    if hitCount > 1, let current = scores[id] {
                        scores[id] = current * (1.0 + Double(hitCount - 1) * 0.3)
                    }
                }
            }

            return scores.sorted { $0.value > $1.value }
                .prefix(limit)
                .compactMap { id, score -> EmailNLPEngine.SearchResult? in
                    guard let email = emailMap[id] else { return nil }
                    return EmailNLPEngine.SearchResult(email: email, score: score, matchContext: "")
                }
        }
    }

    // MARK: - Semantic Search (Vector Similarity)

    func semanticSearch(query: String, limit: Int = 10) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt else { return [] }

        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: query) else {
            return []
        }

        return queue.sync {
            var scored: [(UUID, Double)] = []
            for (id, vector) in emailVectors {
                let similarity = cosineSimilarity(queryVector, vector)
                if similarity > 0.3 {
                    scored.append((id, similarity))
                }
            }

            return scored.sorted { $0.1 > $1.1 }
                .prefix(limit)
                .compactMap { id, score -> EmailNLPEngine.SearchResult? in
                    guard let email = emailMap[id] else { return nil }
                    return EmailNLPEngine.SearchResult(email: email, score: score * 10, matchContext: "")
                }
        }
    }

    // MARK: - Hybrid Search (Keyword + Semantic)

    func hybridSearch(query: String, terms: [String], limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        let keywordResults = search(terms: terms, limit: limit * 2)
        let semanticResults = semanticSearch(query: query, limit: limit)

        var combined: [UUID: (email: MBOXParser.RawEmail, score: Double)] = [:]

        for r in keywordResults {
            combined[r.email.id] = (r.email, r.score)
        }

        for r in semanticResults {
            if let existing = combined[r.email.id] {
                combined[r.email.id] = (existing.email, existing.score + r.score * 0.5)
            } else {
                combined[r.email.id] = (r.email, r.score * 0.5)
            }
        }

        return combined.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { EmailNLPEngine.SearchResult(email: $0.email, score: $0.score, matchContext: "") }
    }

    // MARK: - Clear

    func clear() {
        queue.sync {
            invertedIndex.removeAll()
            emailMap.removeAll()
            emailVectors.removeAll()
            isBuilt = false
        }
    }

    // MARK: - Private

    private func tokenize(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count >= 2 {
                tokens.insert(word)
            }
            return true
        }
        return tokens
    }

    private func buildVectors(for emails: [MBOXParser.RawEmail]) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return }

        for email in emails {
            let subject = email.headers["Subject"] ?? ""
            let bodySnippet = String(bodyText(for: email).prefix(300))
            let text = "\(subject). \(bodySnippet)"

            if let vector = embedding.vector(for: text) {
                emailVectors[email.id] = vector
            }
        }
    }

    private func bodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
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
}
