//
//  AIProvenance.swift
//  mailin
//
//  Every AI answer in mailin can be reproduced and audited. The
//  `AIProvenance` object captures the inputs, intermediate findings, and
//  the model configuration that produced a synthesis result, so claims
//  remain verifiable for legal, forensic, and journalist workflows.
//
//  Stays 100% on-device. Persisted alongside the answer and, when forensic
//  mode is enabled, chained into the HMAC audit log via ForensicManager.
//

import Foundation
import CryptoKit

struct AIProvenance: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let createdAt: Date

    // What the user asked
    let query: String
    let intent: String
    let persona: String

    // What the engine decided to do
    let modelGeneration: String        // "AppleFoundationModel" / "ExtractiveFallback"
    let modelAvailable: Bool
    let cloudCrossValidated: Bool

    // Routing decisions
    let expertsRun: [String]
    let subQueries: [String]
    let toolsUsed: [String]

    // Evidence consumed
    let archiveEmailCount: Int
    let retrievedEmailIDs: [UUID]
    let ragKeyChunkCount: Int

    // Knowledge-graph grounding
    let kgNodeIDs: [String]            // node ids cited in synthesis
    let kgEdgeCount: Int

    // Findings statistics
    let totalFindings: Int
    let highRelevanceCount: Int
    let linkedFindings: Int

    // Synthesis details
    let synthesisLayerCount: Int       // 2/3/4 from hybrid compression tiers
    let contextCharCount: Int
    let answerCharCount: Int

    // Determinism / reproducibility
    let archiveHash: String            // hash of email IDs at synthesis time
    let kgSnapshotHash: String         // hash of KG node ids at synthesis time

    // Cross-references
    let metricsRecordID: UUID?

    // MARK: - Convenience

    /// A compact, human-readable digest suitable for the ForensicManager
    /// audit log. Kept short to avoid bloating the chain.
    var auditDetail: String {
        let topExperts = expertsRun.prefix(4).joined(separator: ",")
        return "intent=\(intent) persona=\(persona) experts=\(topExperts) findings=\(totalFindings)/\(highRelevanceCount)hi linked=\(linkedFindings) kgNodes=\(kgNodeIDs.count) layers=\(synthesisLayerCount) model=\(modelGeneration)"
    }

    /// Verifiable hash of an array of UUID-keyed items. Used to capture the
    /// state of the archive / KG at synthesis time so the same query can be
    /// re-run later and the provenance hashes will match if the data is
    /// unchanged.
    static func hash(of identifiers: [String]) -> String {
        let joined = identifiers.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(ofUUIDs ids: [UUID]) -> String {
        hash(of: ids.map(\.uuidString))
    }
}

// MARK: - Builder

/// Mutable builder used during the hybrid synthesis pipeline. Finalize into
/// an immutable `AIProvenance` once the synthesis completes.
struct AIProvenanceBuilder {
    var id: UUID = UUID()
    let createdAt: Date = Date()

    var query: String = ""
    var intent: String = "general"
    var persona: String = "personal"

    var modelGeneration: String = "AppleFoundationModel"
    var modelAvailable: Bool = true
    var cloudCrossValidated: Bool = false

    var expertsRun: [String] = []
    var subQueries: [String] = []
    var toolsUsed: [String] = []

    var archiveEmailCount: Int = 0
    var retrievedEmailIDs: [UUID] = []
    var ragKeyChunkCount: Int = 0

    var kgNodeIDs: [String] = []
    var kgEdgeCount: Int = 0

    var totalFindings: Int = 0
    var highRelevanceCount: Int = 0
    var linkedFindings: Int = 0

    var synthesisLayerCount: Int = 2
    var contextCharCount: Int = 0
    var answerCharCount: Int = 0

    var archiveHash: String = ""
    var kgSnapshotHash: String = ""

    var metricsRecordID: UUID? = nil

    func build() -> AIProvenance {
        AIProvenance(
            id: id,
            createdAt: createdAt,
            query: query,
            intent: intent,
            persona: persona,
            modelGeneration: modelGeneration,
            modelAvailable: modelAvailable,
            cloudCrossValidated: cloudCrossValidated,
            expertsRun: expertsRun,
            subQueries: subQueries,
            toolsUsed: toolsUsed,
            archiveEmailCount: archiveEmailCount,
            retrievedEmailIDs: retrievedEmailIDs,
            ragKeyChunkCount: ragKeyChunkCount,
            kgNodeIDs: kgNodeIDs,
            kgEdgeCount: kgEdgeCount,
            totalFindings: totalFindings,
            highRelevanceCount: highRelevanceCount,
            linkedFindings: linkedFindings,
            synthesisLayerCount: synthesisLayerCount,
            contextCharCount: contextCharCount,
            answerCharCount: answerCharCount,
            archiveHash: archiveHash,
            kgSnapshotHash: kgSnapshotHash,
            metricsRecordID: metricsRecordID
        )
    }
}

// MARK: - Storage

/// File-based store for the most recent provenance records. Keeps a rolling
/// buffer (newest first) in Application Support so prior answers can have
/// their provenance surfaced from history without keeping everything in RAM.
@MainActor
final class AIProvenanceStore: ObservableObject {
    static let shared = AIProvenanceStore()

    @Published private(set) var recent: [AIProvenance] = []

    private let maxRetained = 200
    private let queue = DispatchQueue(label: "com.mailin.aiprovenance", qos: .utility)

    init() {
        load()
    }

    func record(_ provenance: AIProvenance) {
        recent.insert(provenance, at: 0)
        if recent.count > maxRetained {
            recent.removeLast(recent.count - maxRetained)
        }
        persist()

        // Forensic chain entry (HMAC). Only fires when forensic mode is
        // enabled — so it doesn't pollute the audit log for casual users.
        ForensicManager.shared.logAction(
            "AI Synthesis",
            detail: provenance.auditDetail
        )
    }

    // MARK: - Persistence

    private var storeURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let subdir = dir.appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir.appendingPathComponent("ai-provenance.json")
    }

    private func load() {
        guard let url = storeURL, FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AIProvenance].self, from: data) else { return }
        recent = decoded
    }

    private func persist() {
        let snapshot = recent
        guard let url = storeURL else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
