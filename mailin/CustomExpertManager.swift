import Foundation
import NaturalLanguage

// MARK: - Custom Expert System (v3.5.1)

struct CustomExpert: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var instructions: String
    var keywords: [String]
    var enabled: Bool

    init(name: String, instructions: String, keywords: [String], enabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.instructions = instructions
        self.keywords = keywords
        self.enabled = enabled
    }
}

class CustomExpertManager: ObservableObject {
    static let shared = CustomExpertManager()

    @Published var experts: [CustomExpert] = []

    private let queue = DispatchQueue(label: "com.mailin.customExperts")

    private init() {
        load()
    }

    // MARK: - CRUD

    func addExpert(_ expert: CustomExpert) {
        experts.append(expert)
        save()
    }

    func updateExpert(_ expert: CustomExpert) {
        if let idx = experts.firstIndex(where: { $0.id == expert.id }) {
            experts[idx] = expert
            save()
        }
    }

    func deleteExpert(id: UUID) {
        experts.removeAll { $0.id == id }
        save()
    }

    func enabledExperts() -> [CustomExpert] {
        experts.filter(\.enabled)
    }

    // MARK: - NLEmbedding Scoring

    func scoreExperts(query: String) -> [(expert: CustomExpert, score: Double)] {
        let enabled = enabledExperts()
        guard !enabled.isEmpty else { return [] }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return enabled.map { ($0, 0.3) }
        }

        let qLower = query.lowercased()
        var results: [(expert: CustomExpert, score: Double)] = []

        for expert in enabled {
            var bestSim = -1.0
            let keywordPhrase = expert.keywords.joined(separator: " ")
            let distance = embedding.distance(between: qLower, and: keywordPhrase.lowercased())
            let similarity = 1.0 - distance
            bestSim = max(bestSim, similarity)

            for keyword in expert.keywords {
                let kwDistance = embedding.distance(between: qLower, and: keyword.lowercased())
                let kwSim = 1.0 - kwDistance
                bestSim = max(bestSim, kwSim)
            }

            if qLower.contains(expert.name.lowercased()) {
                bestSim = max(bestSim, 0.8)
            }

            results.append((expert: expert, score: bestSim))
        }

        return results.sorted { $0.score > $1.score }
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_experts.json")
    }

    private func save() {
        queue.async { [experts] in
            if let data = try? JSONEncoder().encode(experts) {
                try? data.write(to: Self.storageURL, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let loaded = try? JSONDecoder().decode([CustomExpert].self, from: data) else {
            return
        }
        experts = loaded
    }

    func reset() {
        experts.removeAll()
        try? FileManager.default.removeItem(at: Self.storageURL)
    }
}
