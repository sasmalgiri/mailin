import Foundation

// MARK: - Feedback-Driven Expert Routing (v3.2.1)

class FeedbackManager {
    static let shared = FeedbackManager()

    struct FeedbackRecord: Codable {
        let intent: String
        let experts: [String]
        let isPositive: Bool
        let timestamp: Date
    }

    private var records: [FeedbackRecord] = []
    private var expertWeights: [String: [String: Double]] = [:]
    private let queue = DispatchQueue(label: "com.mailin.feedback")

    private init() {
        load()
    }

    // MARK: - Record Feedback

    func recordFeedback(intent: String, experts: [String], isPositive: Bool) {
        queue.sync {
            let record = FeedbackRecord(
                intent: intent, experts: experts,
                isPositive: isPositive, timestamp: Date()
            )
            records.append(record)

            // Update expert weights for this intent
            for expert in experts {
                var current = expertWeights[intent, default: [:]][expert, default: 1.0]
                if isPositive {
                    current = min(current + 0.1, 2.0)
                } else {
                    current = max(current - 0.15, 0.3)
                }
                expertWeights[intent, default: [:]][expert] = current
            }

            // Trim old records (keep last 200)
            if records.count > 200 {
                records.removeFirst(records.count - 200)
            }

            save()
        }
    }

    // MARK: - Get Expert Weight Multiplier

    func weightMultiplier(intent: String, expert: String) -> Double {
        queue.sync {
            expertWeights[intent]?[expert] ?? 1.0
        }
    }

    func allWeights(for intent: String) -> [String: Double] {
        queue.sync {
            expertWeights[intent] ?? [:]
        }
    }

    // MARK: - Statistics

    func successRate(for intent: String) -> Double {
        let relevant = queue.sync { records.filter { $0.intent == intent } }
        guard !relevant.isEmpty else { return 0.5 }
        let positive = relevant.filter(\.isPositive).count
        return Double(positive) / Double(relevant.count)
    }

    func totalFeedbackCount() -> Int {
        queue.sync { records.count }
    }

    /// Returns true when the most recent feedback signal (within a short
    /// look-back window) was negative — used by `computeSessionCount` to
    /// widen the parallel expert fan-out for the next query, giving the
    /// user a higher-confidence answer next time.
    ///
    /// - Parameters:
    ///   - intent: the query intent string ("entity", "summary", …)
    ///   - lookBackMinutes: how far back to look. Default 20 minutes — the
    ///     boost should fade within a single session.
    func hadRecentNegativeFeedback(intent: String, lookBackMinutes: Int = 20) -> Bool {
        let cutoff = Date().addingTimeInterval(-Double(lookBackMinutes) * 60)
        return queue.sync {
            for record in records.reversed() {
                if record.timestamp < cutoff { return false }
                guard record.intent == intent else { continue }
                return record.isPositive == false
            }
            return false
        }
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feedback_weights.json")
    }

    private struct PersistenceModel: Codable {
        let records: [FeedbackRecord]
        let weights: [String: [String: Double]]
    }

    private func save() {
        let model = PersistenceModel(records: records, weights: expertWeights)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: Self.storageURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let model = try? JSONDecoder().decode(PersistenceModel.self, from: data) else {
            return
        }
        records = model.records
        expertWeights = model.weights
    }

    // v4.4.1: All weights flattened for sync
    func allWeights() -> [String: Double] {
        queue.sync {
            var flat: [String: Double] = [:]
            for (intent, experts) in expertWeights {
                for (expert, weight) in experts {
                    flat["\(intent):\(expert)"] = weight
                }
            }
            return flat
        }
    }

    // v4.4.1: Merge remote weights (keep higher value for each key)
    func mergeWeights(_ remote: [String: Double]) {
        queue.sync {
            for (key, value) in remote {
                let parts = key.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let intent = String(parts[0])
                let expert = String(parts[1])
                let current = expertWeights[intent, default: [:]][expert, default: 1.0]
                if abs(value - 1.0) > abs(current - 1.0) {
                    expertWeights[intent, default: [:]][expert] = value
                }
            }
            save()
        }
    }

    func reset() {
        queue.sync {
            records.removeAll()
            expertWeights.removeAll()
            try? FileManager.default.removeItem(at: Self.storageURL)
        }
    }
}
