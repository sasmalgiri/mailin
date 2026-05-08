import Foundation
import SwiftUI
import os.log

private let batchLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "ReviewBatch")

@MainActor
class ReviewBatchManager: ObservableObject {
    static let shared = ReviewBatchManager()

    struct ReviewBatch: Identifiable, Codable, @unchecked Sendable {
        let id: UUID
        let name: String
        let emailIDs: [UUID]
        var reviewedIDs: Set<UUID> = []
        var skippedIDs: Set<UUID> = []
        var version: Int = 1

        init(name: String, emailIDs: [UUID]) {
            self.id = UUID()
            self.name = name
            self.emailIDs = emailIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            emailIDs = try c.decode([UUID].self, forKey: .emailIDs)
            reviewedIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .reviewedIDs) ?? []
            skippedIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .skippedIDs) ?? []
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }

        var pendingCount: Int {
            emailIDs.count - reviewedIDs.count - skippedIDs.count
        }
        var progress: Double {
            guard !emailIDs.isEmpty else { return 0 }
            return Double(reviewedIDs.count) / Double(emailIDs.count)
        }
    }

    private static let appSupportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let batchesURL = appSupportDir.appendingPathComponent("review_batches.json")

    @Published var batches: [ReviewBatch] = [] { didSet { save() } }
    @Published var currentBatchIndex: Int = 0 { didSet { save() } }

    private init() { load() }

    private func save() {
        struct Saved: Codable { let version: Int; let batches: [ReviewBatch]; let currentIndex: Int }
        do {
            let data = try JSONEncoder().encode(Saved(version: 1, batches: batches, currentIndex: currentBatchIndex))
            try data.write(to: batchesURL, options: .atomic)
        } catch {
            batchLog.error("Failed to save review batches: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: batchesURL.path) else { return }
        struct Saved: Codable { let version: Int?; let batches: [ReviewBatch]; let currentIndex: Int }
        do {
            let data = try Data(contentsOf: batchesURL)
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            batches = saved.batches
            currentBatchIndex = saved.currentIndex
        } catch {
            batchLog.error("Failed to decode batches: \(error.localizedDescription)")
        }
    }

    var currentBatch: ReviewBatch? {
        guard currentBatchIndex < batches.count else { return nil }
        return batches[currentBatchIndex]
    }

    func createBatches(from emailIDs: [UUID], batchSize: Int = 50, namePrefix: String = "Batch") {
        batches.removeAll()
        let chunks = stride(from: 0, to: emailIDs.count, by: batchSize).map {
            Array(emailIDs[$0..<min($0 + batchSize, emailIDs.count)])
        }
        for (idx, chunk) in chunks.enumerated() {
            batches.append(ReviewBatch(name: "\(namePrefix) \(idx + 1)", emailIDs: chunk))
        }
        currentBatchIndex = 0
        ForensicManager.shared.logAction("Review Batches Created", detail: "\(batches.count) batches of ~\(batchSize) emails each")
    }

    func markReviewed(_ emailID: UUID) {
        guard currentBatchIndex < batches.count else { return }
        batches[currentBatchIndex].reviewedIDs.insert(emailID)
        batches[currentBatchIndex].skippedIDs.remove(emailID)
    }

    func markSkipped(_ emailID: UUID) {
        guard currentBatchIndex < batches.count else { return }
        batches[currentBatchIndex].skippedIDs.insert(emailID)
    }

    func nextBatch() {
        if !batches.isEmpty && currentBatchIndex < batches.count - 1 {
            currentBatchIndex += 1
        }
    }

    func previousBatch() {
        if currentBatchIndex > 0 {
            currentBatchIndex -= 1
        }
    }

    func goToBatch(_ index: Int) {
        guard index >= 0 && index < batches.count else { return }
        currentBatchIndex = index
    }

    func nextUnreviewedID(in batch: ReviewBatch) -> UUID? {
        batch.emailIDs.first { !batch.reviewedIDs.contains($0) && !batch.skippedIDs.contains($0) }
    }

    var totalProgress: Double {
        guard !batches.isEmpty else { return 0 }
        let total = batches.reduce(0) { $0 + $1.emailIDs.count }
        let reviewed = batches.reduce(0) { $0 + $1.reviewedIDs.count }
        return total > 0 ? Double(reviewed) / Double(total) : 0
    }

    func reset() {
        batches.removeAll()
        currentBatchIndex = 0
    }

    func clearAll() { reset() }
}
