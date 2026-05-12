import Foundation
import NaturalLanguage

@MainActor
class PredictiveCodingEngine: ObservableObject {
    static let shared = PredictiveCodingEngine()

    @Published var relevantIDs: Set<UUID> = [] { didSet { if _initialized { persistTags() } } }
    @Published var irrelevantIDs: Set<UUID> = [] { didSet { if _initialized { persistTags() } } }
    @Published var predictions: [UUID: Double] = [:]
    @Published var suggestedForReview: [UUID] = []
    @Published var isTraining = false
    @Published var activeLearningRound: Int = 0
    @Published var confidenceDistribution: [String: Int] = [:]

    private var _initialized = false
    private var emailVectors: [UUID: [Double]] = [:]
    private var emailTokens: [UUID: [String: Double]] = [:]
    private var idfWeights: [String: Double] = [:]
    private var allEmailIDs: [UUID] = []

    private init() {
        loadPersistedTags()
        _initialized = true
    }

    // MARK: - Build

    private static let maxVectorizedEmails = 20_000

    func buildVectors(from emails: [MBOXParser.RawEmail]) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return }
        emailVectors.removeAll()
        emailTokens.removeAll()
        allEmailIDs = emails.map(\.id)

        let processEmails: [MBOXParser.RawEmail]
        if emails.count > Self.maxVectorizedEmails {
            processEmails = Array(emails.prefix(Self.maxVectorizedEmails))
        } else {
            processEmails = emails
        }

        var docFrequency: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)

        for email in processEmails {
            let text = (email.headers["Subject"] ?? "") + ". " + String(email.plainBody.prefix(500))
            if let vec = embedding.vector(for: text) {
                emailVectors[email.id] = vec
            }

            let normalized = text.lowercased()
            tokenizer.string = normalized
            var tf: [String: Double] = [:]
            var uniqueTokens = Set<String>()
            tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
                let word = String(normalized[range])
                if word.count >= 2 {
                    tf[word, default: 0] += 1.0
                    uniqueTokens.insert(word)
                }
                return true
            }
            let maxTF = tf.values.max() ?? 1.0
            for (k, v) in tf { tf[k] = v / maxTF }
            emailTokens[email.id] = tf
            for token in uniqueTokens { docFrequency[token, default: 0] += 1 }
        }

        let n = Double(max(emails.count, 1))
        for (token, df) in docFrequency {
            idfWeights[token] = log(n / Double(df + 1)) + 1.0
        }
    }

    // MARK: - Tagging

    func tagRelevant(_ id: UUID) {
        relevantIDs.insert(id)
        irrelevantIDs.remove(id)
        retrain()
    }

    func tagIrrelevant(_ id: UUID) {
        irrelevantIDs.insert(id)
        relevantIDs.remove(id)
        retrain()
    }

    func removeTag(_ id: UUID) {
        relevantIDs.remove(id)
        irrelevantIDs.remove(id)
        retrain()
    }

    func predictionScore(for id: UUID) -> Double? {
        predictions[id]
    }

    func predictionLabel(for id: UUID) -> String? {
        guard let score = predictions[id] else { return nil }
        if score > 0.7 { return "Likely Relevant" }
        if score < 0.3 { return "Likely Irrelevant" }
        return "Uncertain"
    }

    // MARK: - Training (Naive Bayes + Vector Cosine Ensemble)

    private func retrain() {
        guard !relevantIDs.isEmpty || !irrelevantIDs.isEmpty else {
            predictions.removeAll()
            suggestedForReview.removeAll()
            return
        }
        guard !relevantIDs.isEmpty else {
            predictions = Dictionary(uniqueKeysWithValues: allEmailIDs.map { ($0, 0.3) })
            suggestedForReview = Array(allEmailIDs.prefix(20))
            return
        }

        isTraining = true

        let relIDs = relevantIDs
        let irrIDs = irrelevantIDs
        let tokens = emailTokens
        let vectors = emailVectors
        let idf = idfWeights
        let allIDs = allEmailIDs
        let taggedIDs = relIDs.union(irrIDs)

        Task.detached(priority: .utility) {
            // --- Naive Bayes with TF-IDF ---
            let bayesScores = Self.naiveBayesPredict(
                relevantIDs: relIDs,
                irrelevantIDs: irrIDs,
                emailTokens: tokens,
                idfWeights: idf,
                allIDs: allIDs
            )

            // --- Cosine-SVM (centroid comparison) ---
            let cosineScores = Self.cosinePredict(
                relevantIDs: relIDs,
                irrelevantIDs: irrIDs,
                emailVectors: vectors,
                allIDs: allIDs
            )

            // --- Ensemble: weighted average ---
            let (finalPredictions, suggested) = Self.ensemblePredict(
                bayesScores: bayesScores,
                cosineScores: cosineScores,
                allIDs: allIDs,
                taggedIDs: taggedIDs
            )

            // Compute confidence distribution buckets
            var distribution: [String: Int] = [
                "High Relevant": 0,
                "Likely Relevant": 0,
                "Uncertain": 0,
                "Likely Irrelevant": 0,
                "High Irrelevant": 0
            ]
            for (_, score) in finalPredictions {
                if score >= 0.8 {
                    distribution["High Relevant", default: 0] += 1
                } else if score >= 0.6 {
                    distribution["Likely Relevant", default: 0] += 1
                } else if score >= 0.4 {
                    distribution["Uncertain", default: 0] += 1
                } else if score >= 0.2 {
                    distribution["Likely Irrelevant", default: 0] += 1
                } else {
                    distribution["High Irrelevant", default: 0] += 1
                }
            }

            let finalDistribution = distribution
            await MainActor.run {
                self.predictions = finalPredictions
                self.suggestedForReview = suggested
                self.activeLearningRound += 1
                self.confidenceDistribution = finalDistribution
                self.isTraining = false
            }
        }
    }

    // MARK: - Ensemble

    nonisolated private static func ensemblePredict(
        bayesScores: [UUID: Double],
        cosineScores: [UUID: Double],
        allIDs: [UUID],
        taggedIDs: Set<UUID>
    ) -> ([UUID: Double], [UUID]) {
        var predictions: [UUID: Double] = [:]
        var uncertain: [(UUID, Double)] = []

        for id in allIDs {
            let nb = bayesScores[id] ?? 0.5
            let cos = cosineScores[id] ?? 0.5
            let score = min(1.0, max(0.0, nb * 0.6 + cos * 0.4))
            predictions[id] = score

            if !taggedIDs.contains(id) && score > 0.25 && score < 0.75 {
                uncertain.append((id, abs(score - 0.5)))
            }
        }

        let suggested = uncertain.sorted { $0.1 < $1.1 }.prefix(20).map(\.0)
        return (predictions, Array(suggested))
    }

    // MARK: - Naive Bayes Classifier

    nonisolated private static func naiveBayesPredict(
        relevantIDs: Set<UUID>,
        irrelevantIDs: Set<UUID>,
        emailTokens: [UUID: [String: Double]],
        idfWeights: [String: Double],
        allIDs: [UUID]
    ) -> [UUID: Double] {
        let smoothing = 1.0
        let relevantCount = Double(max(relevantIDs.count, 1))
        let irrelevantCount = Double(max(irrelevantIDs.count, 1))
        let totalTagged = relevantCount + irrelevantCount
        let priorRelevant = log(relevantCount / totalTagged)
        let priorIrrelevant = log(irrelevantCount / totalTagged)

        var relWordScore: [String: Double] = [:]
        var irrWordScore: [String: Double] = [:]
        var vocabulary = Set<String>()

        for id in relevantIDs {
            guard let tfidf = emailTokens[id] else { continue }
            for (word, tf) in tfidf {
                let w = tf * (idfWeights[word] ?? 1.0)
                relWordScore[word, default: 0] += w
                vocabulary.insert(word)
            }
        }
        for id in irrelevantIDs {
            guard let tfidf = emailTokens[id] else { continue }
            for (word, tf) in tfidf {
                let w = tf * (idfWeights[word] ?? 1.0)
                irrWordScore[word, default: 0] += w
                vocabulary.insert(word)
            }
        }

        let totalRel = max(relWordScore.values.reduce(0, +) + smoothing * Double(max(vocabulary.count, 1)), smoothing)
        let totalIrr = max(irrWordScore.values.reduce(0, +) + smoothing * Double(max(vocabulary.count, 1)), smoothing)

        var results: [UUID: Double] = [:]

        for id in allIDs {
            guard let tfidf = emailTokens[id] else {
                results[id] = 0.5
                continue
            }

            var logPosProb = priorRelevant
            var logNegProb = priorIrrelevant

            for (word, tf) in tfidf {
                let idfW = idfWeights[word] ?? 1.0
                let weight = tf * idfW
                let pRel = log((relWordScore[word, default: 0] + smoothing) / totalRel) * weight
                let pIrr = log((irrWordScore[word, default: 0] + smoothing) / totalIrr) * weight
                logPosProb += pRel
                logNegProb += pIrr
            }

            let maxLog = max(logPosProb, logNegProb)
            let probRel = exp(logPosProb - maxLog)
            let probIrr = exp(logNegProb - maxLog)
            let denom = probRel + probIrr
            guard denom > 0 else {
                results[id] = 0.5
                continue
            }
            let posterior = probRel / denom
            results[id] = posterior.isNaN ? 0.5 : posterior
        }

        return results
    }

    // MARK: - Cosine Similarity Predictor

    nonisolated private static func cosinePredict(
        relevantIDs: Set<UUID>,
        irrelevantIDs: Set<UUID>,
        emailVectors: [UUID: [Double]],
        allIDs: [UUID]
    ) -> [UUID: Double] {
        let relVecs = relevantIDs.compactMap { emailVectors[$0] }
        let irrVecs = irrelevantIDs.compactMap { emailVectors[$0] }

        guard let posCentroid = computeCentroid(relVecs) else {
            return Dictionary(uniqueKeysWithValues: allIDs.map { ($0, 0.5) })
        }

        let negCentroid = computeCentroid(irrVecs)

        var results: [UUID: Double] = [:]
        for id in allIDs {
            guard let vec = emailVectors[id] else {
                results[id] = 0.5
                continue
            }
            let posSim = cosineSimilarity(vec, posCentroid)
            let negSim = negCentroid.map { cosineSimilarity(vec, $0) } ?? 0.0
            let score = (posSim - negSim + 1.0) / 2.0
            results[id] = min(1.0, max(0.0, score))
        }
        return results
    }

    nonisolated private static func computeCentroid(_ vectors: [[Double]]) -> [Double]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let dim = first.count
        var sum = [Double](repeating: 0, count: dim)
        for vec in vectors {
            for d in 0..<min(dim, vec.count) { sum[d] += vec[d] }
        }
        let count = Double(vectors.count)
        guard count > 0 else { return nil }
        return sum.map { $0 / count }
    }

    nonisolated private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0, !denom.isNaN else { return 0 }
        let result = dot / denom
        return result.isNaN ? 0 : result
    }

    // MARK: - Statistics

    var f1Score: Double? {
        guard !relevantIDs.isEmpty && !irrelevantIDs.isEmpty else { return nil }
        let taggedIDs = relevantIDs.union(irrelevantIDs)
        var tp = 0, fp = 0, fn = 0
        for id in taggedIDs {
            let isRelevant = relevantIDs.contains(id)
            let predicted = (predictions[id] ?? 0.5) > 0.5
            if isRelevant && predicted { tp += 1 }
            else if !isRelevant && predicted { fp += 1 }
            else if isRelevant && !predicted { fn += 1 }
        }
        let precision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : 0
        let recall = tp + fn > 0 ? Double(tp) / Double(tp + fn) : 0
        guard precision + recall > 0 else { return nil }
        return 2.0 * precision * recall / (precision + recall)
    }

    var richness: Double {
        guard !predictions.isEmpty else { return 0 }
        let predicted = predictions.values.filter { $0 > 0.5 }.count
        return Double(predicted) / Double(predictions.count)
    }

    // MARK: - Active Learning Enhancements

    func activeLearningStats() -> (round: Int, tagged: Int, predicted: Int, f1: Double?, richness: Double) {
        let tagged = relevantIDs.count + irrelevantIDs.count
        let predicted = predictions.count
        return (round: activeLearningRound, tagged: tagged, predicted: predicted, f1: f1Score, richness: richness)
    }

    func mostInformativeSamples(count: Int = 10) -> [UUID] {
        let taggedIDs = relevantIDs.union(irrelevantIDs)
        return predictions
            .filter { !taggedIDs.contains($0.key) }
            .map { (id: $0.key, distance: abs($0.value - 0.5)) }
            .sorted { $0.distance < $1.distance }
            .prefix(count)
            .map(\.id)
    }

    func reset() {
        relevantIDs.removeAll()
        irrelevantIDs.removeAll()
        predictions.removeAll()
        suggestedForReview.removeAll()
        emailVectors.removeAll()
        emailTokens.removeAll()
        idfWeights.removeAll()
        allEmailIDs.removeAll()
    }

    func clearAll() { reset() }

    // MARK: - Persistence

    private static let tagsURL: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("predictive_tags.json")
    }()

    private struct PersistedTags: Codable {
        let relevant: [String]
        let irrelevant: [String]
    }

    private func persistTags() {
        let data = PersistedTags(
            relevant: relevantIDs.map(\.uuidString),
            irrelevant: irrelevantIDs.map(\.uuidString)
        )
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.tagsURL, options: .atomic)
        } catch {
            print("[PredictiveCoding] Failed to persist tags: \(error.localizedDescription)")
        }
    }

    func loadPersistedTags() {
        guard FileManager.default.fileExists(atPath: Self.tagsURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.tagsURL),
              let decoded = try? JSONDecoder().decode(PersistedTags.self, from: data) else { return }
        relevantIDs = Set(decoded.relevant.compactMap { UUID(uuidString: $0) })
        irrelevantIDs = Set(decoded.irrelevant.compactMap { UUID(uuidString: $0) })
    }
}
