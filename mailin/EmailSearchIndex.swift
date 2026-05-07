import Foundation
import NaturalLanguage
import PDFKit
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class EmailSearchIndex {
    static let shared = EmailSearchIndex()

    private var invertedIndex: [String: Set<UUID>] = [:]
    private var emailMap: [UUID: MBOXParser.RawEmail] = [:]
    private var emailVectors: [UUID: [Double]] = [:]
    private var attachmentTextCache: [UUID: String] = [:]
    private var isBuilt = false
    private let queue = DispatchQueue(label: "com.mailin.searchindex", qos: .userInitiated)

    // BM25 infrastructure
    private var termDocFreqs: [String: [UUID: Int]] = [:]
    private var docLengths: [UUID: Int] = [:]
    private var avgDocLength: Double = 0
    private let bm25K1: Double = 1.2
    private let bm25B: Double = 0.75

    private static let appSupportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let indexURL = appSupportDir.appendingPathComponent("search_index.bin")
    private let metaURL = appSupportDir.appendingPathComponent("search_index_meta.json")

    var indexedCount: Int { emailMap.count }

    // MARK: - Build Index

    func build(from emails: [MBOXParser.RawEmail]) {
        queue.sync {
            invertedIndex.removeAll()
            emailMap.removeAll()
            emailVectors.removeAll()
            attachmentTextCache.removeAll()
            termDocFreqs.removeAll()
            docLengths.removeAll()

            for email in emails {
                emailMap[email.id] = email

                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let body = bodyText(for: email).lowercased()

                let attachmentText = extractAttachmentText(for: email)
                if !attachmentText.isEmpty {
                    attachmentTextCache[email.id] = attachmentText
                }

                let allText = "\(from) \(to) \(subject) \(body) \(attachmentText.lowercased())"
                let tokens = tokenize(allText)
                let tokenArray = tokenizeWithFrequency(allText)

                for token in tokens {
                    invertedIndex[token, default: []].insert(email.id)
                }
                for (token, count) in tokenArray {
                    termDocFreqs[token, default: [:]][email.id] = count
                }
                docLengths[email.id] = tokenArray.values.reduce(0, +)
            }

            let totalLen = docLengths.values.reduce(0, +)
            avgDocLength = docLengths.isEmpty ? 1.0 : Double(totalLen) / Double(docLengths.count)

            buildVectors(for: emails)
            isBuilt = true
        }
        saveToDisk()
    }

    func buildAsync(from emails: [MBOXParser.RawEmail], completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.invertedIndex.removeAll()
            self.emailMap.removeAll()
            self.emailVectors.removeAll()
            self.attachmentTextCache.removeAll()
            self.termDocFreqs.removeAll()
            self.docLengths.removeAll()

            for email in emails {
                self.emailMap[email.id] = email

                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let body = self.bodyText(for: email).lowercased()

                let attachmentText = self.extractAttachmentText(for: email)
                if !attachmentText.isEmpty {
                    self.attachmentTextCache[email.id] = attachmentText
                }

                let allText = "\(from) \(to) \(subject) \(body) \(attachmentText.lowercased())"
                let tokens = self.tokenize(allText)
                let tokenArray = self.tokenizeWithFrequency(allText)

                for token in tokens {
                    self.invertedIndex[token, default: []].insert(email.id)
                }
                for (token, count) in tokenArray {
                    self.termDocFreqs[token, default: [:]][email.id] = count
                }
                self.docLengths[email.id] = tokenArray.values.reduce(0, +)
            }

            let totalLen = self.docLengths.values.reduce(0, +)
            self.avgDocLength = self.docLengths.isEmpty ? 1.0 : Double(totalLen) / Double(self.docLengths.count)

            self.buildVectors(for: emails)
            self.isBuilt = true
            self.saveToDisk()

            Task { @MainActor in completion?() }
        }
    }

    // MARK: - Persistence

    private struct SerializedIndex: Codable {
        let version: Int
        let emailCount: Int
        let indexEntries: [[String: [String]]]
        let attachmentTexts: [String: String]
    }

    func saveToDisk() {
        queue.async { [weak self] in
            guard let self, self.isBuilt else { return }
            var entries: [[String: [String]]] = []
            var batch: [String: [String]] = [:]
            var count = 0
            for (term, ids) in self.invertedIndex {
                batch[term] = ids.map(\.uuidString)
                count += 1
                if count % 5000 == 0 {
                    entries.append(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { entries.append(batch) }

            var attTexts: [String: String] = [:]
            for (id, text) in self.attachmentTextCache {
                attTexts[id.uuidString] = String(text.prefix(10000))
            }

            let serialized = SerializedIndex(
                version: 2,
                emailCount: self.emailMap.count,
                indexEntries: entries,
                attachmentTexts: attTexts
            )
            guard let data = try? JSONEncoder().encode(serialized) else { return }
            try? data.write(to: self.indexURL, options: .atomic)

            let meta: [String: Any] = [
                "version": 2,
                "emailCount": self.emailMap.count,
                "termCount": self.invertedIndex.count,
                "savedAt": ISO8601DateFormatter().string(from: Date())
            ]
            if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
                try? metaData.write(to: self.metaURL, options: .atomic)
            }
        }
    }

    func loadFromDisk(emails: [MBOXParser.RawEmail]) -> Bool {
        return queue.sync {
            guard let data = try? Data(contentsOf: indexURL),
                  let serialized = try? JSONDecoder().decode(SerializedIndex.self, from: data),
                  serialized.version >= 2,
                  serialized.emailCount == emails.count else {
                return false
            }

            invertedIndex.removeAll()
            for batch in serialized.indexEntries {
                for (term, idStrings) in batch {
                    let ids = Set(idStrings.compactMap { UUID(uuidString: $0) })
                    if !ids.isEmpty { invertedIndex[term] = ids }
                }
            }

            emailMap.removeAll()
            termDocFreqs.removeAll()
            docLengths.removeAll()
            for email in emails {
                emailMap[email.id] = email
                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let body = bodyText(for: email).lowercased()
                let allText = "\(from) \(to) \(subject) \(body)"
                let tokenArray = tokenizeWithFrequency(allText)
                for (token, count) in tokenArray {
                    termDocFreqs[token, default: [:]][email.id] = count
                }
                docLengths[email.id] = tokenArray.values.reduce(0, +)
            }
            let totalLen = docLengths.values.reduce(0, +)
            avgDocLength = docLengths.isEmpty ? 1.0 : Double(totalLen) / Double(docLengths.count)

            attachmentTextCache.removeAll()
            for (idStr, text) in serialized.attachmentTexts {
                if let id = UUID(uuidString: idStr) {
                    attachmentTextCache[id] = text
                }
            }

            buildVectors(for: emails)
            isBuilt = true
            return true
        }
    }

    func deleteDiskCache() {
        try? FileManager.default.removeItem(at: indexURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    // MARK: - Keyword Search (Instant via Inverted Index)

    func search(terms: [String], limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt, !terms.isEmpty else { return [] }

        let cappedTerms = Array(terms.prefix(200))
        let lowerTerms = cappedTerms.map { String($0.lowercased().prefix(500)) }
        let n = Double(max(emailMap.count, 1))

        return queue.sync {
            var scores: [UUID: Double] = [:]

            for term in lowerTerms {
                var matchingTerms: [(String, Set<UUID>)] = []
                if let exact = invertedIndex[term] {
                    matchingTerms.append((term, exact))
                } else if term.count >= 4 {
                    let stem = String(term.prefix(term.count - 1))
                    for (key, ids) in invertedIndex where key.hasPrefix(stem) {
                        matchingTerms.append((key, ids))
                    }
                }

                for (matchedTerm, matchingIDs) in matchingTerms {
                    let df = Double(matchingIDs.count)
                    let idf = log((n - df + 0.5) / (df + 0.5) + 1.0)

                    for id in matchingIDs {
                        guard let email = emailMap[id] else { continue }
                        let tf = Double(termDocFreqs[matchedTerm]?[id] ?? 1)
                        let dl = Double(docLengths[id] ?? 1)
                        let bm25 = idf * (tf * (bm25K1 + 1)) / (tf + bm25K1 * (1 - bm25B + bm25B * dl / avgDocLength))

                        // Field-weighted boost: subject/from/to matches are more important
                        var fieldBoost = 1.0
                        let from = (email.headers["From"] ?? "").lowercased()
                        let to = (email.headers["To"] ?? "").lowercased()
                        let subject = (email.headers["Subject"] ?? "").lowercased()
                        if from.contains(term) { fieldBoost += 3.0 }
                        if to.contains(term) { fieldBoost += 2.5 }
                        if subject.contains(term) { fieldBoost += 2.0 }

                        scores[id, default: 0] += bm25 * fieldBoost
                    }
                }
            }

            // Multi-term coordination bonus
            if lowerTerms.count > 1 {
                for (id, _) in scores {
                    var hitCount = 0
                    for term in lowerTerms {
                        if invertedIndex[term]?.contains(id) == true { hitCount += 1 }
                        else if term.count >= 4 {
                            let stem = String(term.prefix(term.count - 1))
                            if invertedIndex.keys.contains(where: { $0.hasPrefix(stem) && (invertedIndex[$0]?.contains(id) == true) }) {
                                hitCount += 1
                            }
                        }
                    }
                    if hitCount > 1, let current = scores[id] {
                        scores[id] = current * (1.0 + Double(hitCount - 1) * 0.4)
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

    // MARK: - Boolean Search (AND / OR / NOT)

    indirect enum BooleanOp {
        case term(String)
        case and([BooleanOp])
        case or([BooleanOp])
        case not(BooleanOp)
    }

    func booleanSearch(query: String, limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt else { return [] }
        let ast = parseBooleanQuery(query)
        return queue.sync {
            let matchedIDs = evaluateBoolean(ast)
            return matchedIDs.prefix(limit).compactMap { id -> EmailNLPEngine.SearchResult? in
                guard let email = emailMap[id] else { return nil }
                return EmailNLPEngine.SearchResult(email: email, score: 1.0, matchContext: "")
            }
        }
    }

    func parseBooleanQuery(_ query: String) -> BooleanOp {
        let tokens = tokenizeBooleanQuery(query)
        var index = 0
        return parseOrExpression(tokens, &index)
    }

    private func tokenizeBooleanQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in query {
            if char == "\"" {
                inQuotes.toggle()
                if !inQuotes && !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else if char == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func parseOrExpression(_ tokens: [String], _ index: inout Int) -> BooleanOp {
        var left = parseAndExpression(tokens, &index)
        while index < tokens.count && tokens[index].uppercased() == "OR" {
            index += 1
            let right = parseAndExpression(tokens, &index)
            left = .or([left, right])
        }
        return left
    }

    private func parseAndExpression(_ tokens: [String], _ index: inout Int) -> BooleanOp {
        var left = parseUnaryExpression(tokens, &index)
        while index < tokens.count {
            let upper = tokens[index].uppercased()
            if upper == "AND" {
                index += 1
                let right = parseUnaryExpression(tokens, &index)
                left = .and([left, right])
            } else if upper != "OR" && upper != "NOT" {
                let right = parseUnaryExpression(tokens, &index)
                left = .and([left, right])
            } else {
                break
            }
        }
        return left
    }

    private func parseUnaryExpression(_ tokens: [String], _ index: inout Int) -> BooleanOp {
        guard index < tokens.count else { return .term("") }
        if tokens[index].uppercased() == "NOT" {
            index += 1
            let operand = parseUnaryExpression(tokens, &index)
            return .not(operand)
        }
        let term = tokens[index].lowercased()
        index += 1
        return .term(term)
    }

    private func evaluateBoolean(_ node: BooleanOp) -> [UUID] {
        switch node {
        case .term(let word):
            guard !word.isEmpty else { return [] }
            if let ids = invertedIndex[word] {
                return Array(ids)
            }
            var partial = Set<UUID>()
            if word.count >= 3 {
                for (key, ids) in invertedIndex where key.hasPrefix(word) {
                    partial.formUnion(ids)
                }
            }
            return Array(partial)
        case .and(let children):
            guard let first = children.first else { return [] }
            var result = Set(evaluateBoolean(first))
            for child in children.dropFirst() {
                result.formIntersection(evaluateBoolean(child))
            }
            return Array(result)
        case .or(let children):
            var result = Set<UUID>()
            for child in children {
                result.formUnion(evaluateBoolean(child))
            }
            return Array(result)
        case .not(let child):
            let excluded = Set(evaluateBoolean(child))
            return Array(Set(emailMap.keys).subtracting(excluded))
        }
    }

    // MARK: - Regex Search

    func regexSearch(pattern: String, limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt, pattern.count <= 1000 else { return [] }
        let cleanPattern: String
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            cleanPattern = String(pattern.dropFirst().dropLast())
        } else {
            cleanPattern = pattern.replacingOccurrences(of: "*", with: ".*")
        }
        guard let regex = try? NSRegularExpression(pattern: cleanPattern, options: .caseInsensitive) else { return [] }

        return queue.sync {
            var results: [EmailNLPEngine.SearchResult] = []
            for (_, email) in emailMap {
                let text = String(email.fullText.prefix(100_000))
                let nsText = text as NSString
                let range = NSRange(location: 0, length: nsText.length)
                regex.enumerateMatches(in: text, options: .withoutAnchoringBounds, range: range) { match, _, stop in
                    if match != nil {
                        results.append(EmailNLPEngine.SearchResult(email: email, score: 1.0, matchContext: ""))
                        stop.pointee = true
                    }
                }
                if results.count >= limit { break }
            }
            return results
        }
    }

    // MARK: - Proximity Search

    func proximitySearch(term1: String, term2: String, maxDistance: Int, limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt else { return [] }
        let t1 = term1.lowercased(), t2 = term2.lowercased()

        return queue.sync {
            var results: [EmailNLPEngine.SearchResult] = []
            for (_, email) in emailMap {
                let text = email.fullText.lowercased()
                let words = text.split(separator: " ").map(String.init)
                let positions1 = words.enumerated().filter { $0.element.contains(t1) }.map(\.offset)
                let positions2 = words.enumerated().filter { $0.element.contains(t2) }.map(\.offset)
                for p1 in positions1 {
                    for p2 in positions2 {
                        if abs(p1 - p2) <= maxDistance {
                            results.append(EmailNLPEngine.SearchResult(email: email, score: Double(maxDistance - abs(p1 - p2) + 1), matchContext: ""))
                            break
                        }
                    }
                    if results.last?.email.id == email.id { break }
                }
                if results.count >= limit { break }
            }
            return results.sorted { $0.score > $1.score }
        }
    }

    // MARK: - Chunk-Level Search

    struct ChunkResult {
        let email: MBOXParser.RawEmail
        let chunk: String
        let score: Double
    }

    func chunkSearch(terms: [String], in emails: [MBOXParser.RawEmail], maxChunksPerEmail: Int = 2, limit: Int = 10) -> [ChunkResult] {
        guard !terms.isEmpty else { return [] }
        let lowerTerms = terms.map { $0.lowercased() }
        var results: [ChunkResult] = []

        for email in emails {
            let body = bodyText(for: email)
            guard !body.isEmpty else { continue }
            let chunks = splitIntoChunks(body, maxTokens: 200)

            var scored: [(chunk: String, score: Double)] = []
            for chunk in chunks {
                let lower = chunk.lowercased()
                var score = 0.0
                var hitCount = 0

                for term in lowerTerms {
                    var tf = 0
                    var searchStart = lower.startIndex
                    while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                        tf += 1
                        searchStart = range.upperBound
                        if tf >= 10 { break }
                    }
                    if tf > 0 {
                        score += Double(tf)
                        hitCount += 1
                    }
                }

                if hitCount > 1 { score *= 1.0 + Double(hitCount - 1) * 0.5 }
                if lower.contains("?") { score *= 1.15 }
                if lower.range(of: #"\d"#, options: .regularExpression) != nil { score *= 1.1 }

                let wordCount = chunk.split(separator: " ").count
                if wordCount >= 15 && wordCount <= 200 { score *= 1.1 }

                if score > 0 { scored.append((chunk, score)) }
            }

            for (chunk, score) in scored.sorted(by: { $0.score > $1.score }).prefix(maxChunksPerEmail) {
                results.append(ChunkResult(email: email, chunk: chunk, score: score))
            }
        }

        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Thread Expansion

    func expandByThread(_ initialEmails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail], maxExpanded: Int = 50) -> [MBOXParser.RawEmail] {
        var initialIDs = Set(initialEmails.map(\.id))
        var threadSubjects = Set<String>()
        var messageIDs = Set<String>()

        for email in initialEmails {
            if let subject = email.headers["Subject"] {
                let cleaned = subject
                    .replacingOccurrences(of: "Re: ", with: "")
                    .replacingOccurrences(of: "Fwd: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if cleaned.count >= 3 { threadSubjects.insert(cleaned) }
            }
            if let msgID = email.headers["Message-ID"] { messageIDs.insert(msgID) }
            if let refs = email.headers["References"] {
                for ref in refs.components(separatedBy: " ") where ref.contains("@") {
                    messageIDs.insert(ref.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if let inReply = email.headers["In-Reply-To"], !inReply.isEmpty {
                messageIDs.insert(inReply.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var expanded = initialEmails
        for email in allEmails {
            guard !initialIDs.contains(email.id) else { continue }
            if expanded.count >= maxExpanded { break }

            if let inReply = email.headers["In-Reply-To"], !inReply.isEmpty,
               messageIDs.contains(inReply.trimmingCharacters(in: .whitespacesAndNewlines)) {
                expanded.append(email)
                initialIDs.insert(email.id)
                if let msgID = email.headers["Message-ID"] { messageIDs.insert(msgID) }
                continue
            }

            if let refs = email.headers["References"] {
                let refList = refs.components(separatedBy: " ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.contains("@") }
                if refList.contains(where: { messageIDs.contains($0) }) {
                    expanded.append(email)
                    initialIDs.insert(email.id)
                    if let msgID = email.headers["Message-ID"] { messageIDs.insert(msgID) }
                    continue
                }
            }

            if let subject = email.headers["Subject"] {
                let cleaned = subject
                    .replacingOccurrences(of: "Re: ", with: "")
                    .replacingOccurrences(of: "Fwd: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if cleaned.count >= 3 && threadSubjects.contains(cleaned) {
                    expanded.append(email)
                    initialIDs.insert(email.id)
                }
            }
        }

        return expanded
    }

    private func splitIntoChunks(_ text: String, maxTokens: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") && !$0.lowercased().hasPrefix("content-type:") }

        var chunks: [String] = []
        var current = ""
        var currentTokenEst = 0

        for para in paragraphs {
            let paraTokens = max(para.count / 4, 1)
            if currentTokenEst + paraTokens > maxTokens && !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                currentTokenEst = 0
            }
            current += para + "\n\n"
            currentTokenEst += paraTokens
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chunks.append(trimmed) }

        return chunks
    }

    // MARK: - Attachment Content Search

    func searchAttachmentContent(terms: [String], limit: Int = 15) -> [EmailNLPEngine.SearchResult] {
        guard isBuilt, !terms.isEmpty else { return [] }
        let lowerTerms = terms.map { $0.lowercased() }

        return queue.sync {
            var results: [EmailNLPEngine.SearchResult] = []
            for (_, email) in emailMap {
                guard let text = attachmentTextCache[email.id], !text.isEmpty else { continue }
                let lower = text.lowercased()
                var score = 0.0
                for term in lowerTerms {
                    if lower.contains(term) { score += 1.0 }
                }
                if score > 0 {
                    results.append(EmailNLPEngine.SearchResult(email: email, score: score, matchContext: "Found in attachment"))
                }
                if results.count >= limit { break }
            }
            return results.sorted { $0.score > $1.score }
        }
    }

    // MARK: - Clear

    func clear() {
        queue.sync {
            invertedIndex.removeAll()
            emailMap.removeAll()
            emailVectors.removeAll()
            attachmentTextCache.removeAll()
            termDocFreqs.removeAll()
            docLengths.removeAll()
            avgDocLength = 0
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

    private func tokenizeWithFrequency(_ text: String) -> [String: Int] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var freq: [String: Int] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count >= 2 {
                freq[word, default: 0] += 1
            }
            return true
        }
        return freq
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

    private func extractAttachmentText(for email: MBOXParser.RawEmail) -> String {
        var texts: [String] = []
        for attachment in email.attachments {
            let mime = attachment.mimeType.lowercased()
            let filename = attachment.filename.lowercased()

            if mime == "application/pdf" || filename.hasSuffix(".pdf") {
                if let text = extractPDFText(attachment) {
                    texts.append(text)
                }
            } else if mime == "application/rtf" || mime == "text/rtf" || filename.hasSuffix(".rtf") {
                if let text = extractRTFText(attachment) {
                    texts.append(text)
                }
            } else if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" || filename.hasSuffix(".docx") {
                if let text = extractDOCXText(attachment) {
                    texts.append(text)
                }
            } else if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic"].contains(where: { filename.hasSuffix(".\($0)") }) {
                let ocrText = extractOCRText(from: attachment)
                if !ocrText.isEmpty {
                    texts.append("ocr: \(ocrText)")
                } else if let text = ocrImageAttachment(attachment) {
                    texts.append("ocr: \(text)")
                }
            }
        }
        return texts.joined(separator: " ")
    }

    private func attachmentData(_ attachment: AttachmentMetadata) -> Data? {
        if let b64 = attachment.base64, let data = Data(base64Encoded: b64) {
            return data
        }
        if let url = attachment.fileURL, let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    private func extractPDFText(_ attachment: AttachmentMetadata) -> String? {
        guard let data = attachmentData(attachment),
              let doc = PDFDocument(data: data) else { return nil }
        if let text = doc.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return ocrPDFDocument(doc)
    }

    private func ocrPDFDocument(_ doc: PDFDocument) -> String? {
        var texts: [String] = []
        let pageCount = min(doc.pageCount, 20)
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            #if os(macOS)
            guard let tiff = image.tiffRepresentation,
                  let text = runOCR(on: tiff) else { continue }
            #else
            guard let pngData = image.pngData(),
                  let text = runOCR(on: pngData) else { continue }
            #endif
            texts.append(text)
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private func ocrImageAttachment(_ attachment: AttachmentMetadata) -> String? {
        guard let data = attachmentData(attachment) else { return nil }
        return runOCR(on: data)
    }

    /// Extracts OCR text from an image attachment using the Vision framework.
    /// Supports PNG, JPG, JPEG, TIFF, TIF, BMP, GIF, and HEIC formats.
    private func extractOCRText(from attachment: AttachmentMetadata) -> String {
        guard let data = attachmentData(attachment) else { return "" }
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic"]
        guard imageExtensions.contains(ext) else { return "" }

        guard let platformImage = PlatformImage(data: data),
              let cgImage = platformImage.cgImageCompat else { return "" }

        var ocrText = ""
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            ocrText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return ocrText
    }

    private func runOCR(on imageData: Data) -> String? {
        guard let platformImage = PlatformImage(data: imageData),
              let cgImage = platformImage.cgImageCompat else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observations = request.results else { return nil }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func extractRTFText(_ attachment: AttachmentMetadata) -> String? {
        guard let data = attachmentData(attachment) else { return nil }
        guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return nil }
        return attributed.string
    }

    private func extractDOCXText(_ attachment: AttachmentMetadata) -> String? {
        guard let data = attachmentData(attachment) else { return nil }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let zipURL = tempDir.appendingPathComponent("doc.zip")
            try data.write(to: zipURL)
            let extractDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            guard let archive = try? Data(contentsOf: zipURL),
                  archive.count > 4 else { return nil }

            let docXML = tempDir.appendingPathComponent("document.xml")
            if extractDocXMLFromZip(data: archive, to: docXML) {
                let xmlData = try Data(contentsOf: docXML)
                return parseDocXML(xmlData)
            }
        } catch {
            _ = error
        }
        return nil
    }

    private func extractDocXMLFromZip(data: Data, to destination: URL) -> Bool {
        var offset = 0
        while offset + 30 < data.count {
            guard data[offset] == 0x50, data[offset+1] == 0x4B,
                  data[offset+2] == 0x03, data[offset+3] == 0x04 else { break }
            let fnLen = Int(data[offset+26]) | (Int(data[offset+27]) << 8)
            let extraLen = Int(data[offset+28]) | (Int(data[offset+29]) << 8)
            let compSize = Int(data[offset+18]) | (Int(data[offset+19]) << 8) | (Int(data[offset+20]) << 16) | (Int(data[offset+21]) << 24)
            let headerEnd = offset + 30
            guard headerEnd + fnLen <= data.count else { break }
            let filename = String(data: data[headerEnd..<headerEnd+fnLen], encoding: .utf8) ?? ""
            let dataStart = headerEnd + fnLen + extraLen
            if filename == "word/document.xml" && dataStart + compSize <= data.count {
                let fileData = data[dataStart..<dataStart+compSize]
                do {
                    let decompressed = try (fileData as NSData).decompressed(using: .zlib) as Data
                    try decompressed.write(to: destination)
                    return true
                } catch {
                    try? fileData.write(to: destination)
                    return true
                }
            }
            offset = dataStart + compSize
        }
        return false
    }

    private func parseDocXML(_ data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let stripped = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let cleaned = stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(5000))
    }
}
