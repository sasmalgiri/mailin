//
//  AIMetrics.swift
//  mailin
//
//  Lightweight per-query instrumentation for the hybrid AI pipeline.
//  Lets us prove (or disprove) that each architectural change actually
//  improves quality, latency, or citation density.
//
//  Stays 100% on-device. Stored in Application Support, never transmitted.
//

import Foundation
import os

@MainActor
final class AIMetrics: ObservableObject {
    static let shared = AIMetrics()

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "AIMetrics")
    private let queue = DispatchQueue(label: "com.mailin.aimetrics", qos: .utility)
    private let maxRetained = 500

    @Published private(set) var recent: [QueryRecord] = []

    // MARK: - Record Schema

    struct QueryRecord: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let query: String
        let intent: String
        let persona: String
        let archiveEmailCount: Int

        // Routing
        var expertsRun: [String] = []
        var subQueryCount: Int = 0
        var toolsUsed: [String] = []

        // Findings
        var totalFindings: Int = 0
        var highRelevanceCount: Int = 0
        var findingsLinkedToEmails: Int = 0
        var kgNodesCited: Int = 0

        // Compression
        var synthesisLayerCount: Int = 0
        var contextChars: Int = 0

        // Output
        var answerCharCount: Int = 0
        var citedEmailCount: Int = 0

        // Timing (ms)
        var totalElapsedMs: Int = 0
        var retrievalElapsedMs: Int = 0
        var expertsElapsedMs: Int = 0
        var synthesisElapsedMs: Int = 0

        // Outcome
        var didFail: Bool = false
        var fallbackUsed: Bool = false

        // Optional user feedback collected later
        var userRating: Int? = nil

        init(query: String, intent: String, persona: String, archiveEmailCount: Int) {
            self.id = UUID()
            self.timestamp = Date()
            self.query = String(query.prefix(280))
            self.intent = intent
            self.persona = persona
            self.archiveEmailCount = archiveEmailCount
        }
    }

    // MARK: - Recording

    /// Begin tracking a new query. The returned builder is value-typed; pass
    /// it through the pipeline and finalize when the answer is ready.
    func begin(query: String, intent: String, persona: String, archiveEmailCount: Int) -> QueryRecord {
        QueryRecord(query: query, intent: intent, persona: persona, archiveEmailCount: archiveEmailCount)
    }

    func finalize(_ record: QueryRecord) {
        recent.insert(record, at: 0)
        if recent.count > maxRetained { recent.removeLast(recent.count - maxRetained) }
        persist(record)
        log.info("AI query: intent=\(record.intent, privacy: .public) experts=\(record.expertsRun.count) findings=\(record.totalFindings) cited=\(record.citedEmailCount) elapsedMs=\(record.totalElapsedMs)")
    }

    /// Convenience: time a block and return both result and elapsed milliseconds.
    static func timed<T>(_ work: () async throws -> T) async rethrows -> (T, Int) {
        let start = Date()
        let value = try await work()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return (value, ms)
    }

    // MARK: - Persistence

    private var storeURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let subdir = dir.appendingPathComponent("mailin/metrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir.appendingPathComponent("ai-metrics.jsonl")
    }

    private func persist(_ record: QueryRecord) {
        guard let url = storeURL else { return }
        queue.async {
            guard let line = try? JSONEncoder().encode(record),
                  let nl = "\n".data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    handle.write(nl)
                    try? handle.close()
                }
            } else {
                var data = line
                data.append(nl)
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Aggregate views

    /// Returns the rolling average over the last N records.
    func summary(lastN: Int = 50) -> Summary {
        let slice = Array(recent.prefix(lastN))
        guard !slice.isEmpty else { return Summary() }
        let count = Double(slice.count)
        return Summary(
            sampleSize: slice.count,
            avgElapsedMs: Int(slice.map { Double($0.totalElapsedMs) }.reduce(0, +) / count),
            avgFindings: slice.map { Double($0.totalFindings) }.reduce(0, +) / count,
            avgHighRelevance: slice.map { Double($0.highRelevanceCount) }.reduce(0, +) / count,
            avgCitedEmails: slice.map { Double($0.citedEmailCount) }.reduce(0, +) / count,
            avgKGNodes: slice.map { Double($0.kgNodesCited) }.reduce(0, +) / count,
            fallbackRate: Double(slice.filter { $0.fallbackUsed }.count) / count,
            failureRate: Double(slice.filter { $0.didFail }.count) / count
        )
    }

    struct Summary {
        var sampleSize: Int = 0
        var avgElapsedMs: Int = 0
        var avgFindings: Double = 0
        var avgHighRelevance: Double = 0
        var avgCitedEmails: Double = 0
        var avgKGNodes: Double = 0
        var fallbackRate: Double = 0
        var failureRate: Double = 0
    }
}
