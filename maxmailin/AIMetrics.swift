//
//  AIMetrics.swift
//  mailin
//
//  Lightweight per-query instrumentation for the hybrid AI pipeline, so a
//  claim about its latency, citation density or failure rate can be checked
//  against recorded queries instead of asserted.
//
//  Recorded by `AIAssistantView.askAI()`: every engine branch and every
//  early-return path (greeting, acknowledgment, smart-query shortcut) begins
//  a record and finalizes it, including on failure and on cancellation.
//
//  HOW A ZERO STAYS HONEST. Engines see different things — the NLP path knows
//  its findings counts; the streaming Apple AI path does not, and its expert
//  pipeline runs inside a call this view cannot inspect. So each record
//  carries `reported`: the field groups its engine actually measured.
//  `summary(lastN:)` averages each metric only over the records that reported
//  its group and returns the size of that subset, so an unmeasured metric
//  reads as "not measured" rather than as 0.0. Filling every field with
//  whatever was to hand would have produced numbers that look complete and
//  are not — which is worse than none, and is the thing this file exists to
//  prevent.
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

        /// Which field GROUPS the recording path actually measured.
        ///
        /// Not decoration — it is what keeps a zero honest. Engines differ in
        /// what they can see: the NLP path knows its findings counts, the
        /// streaming Apple AI path does not, and its expert pipeline runs
        /// inside a call this view cannot inspect. Averaging `totalFindings`
        /// across every record would dilute the engines that do measure it
        /// with zeros from the engines that cannot, and report the result as
        /// a measurement. `summary(lastN:)` averages each metric only over the
        /// records that reported its group, and says how many those were.
        ///
        /// A field outside these groups is UNMEASURED, not zero.
        var reported: Set<String> = []

        enum Group {
            /// query, intent, persona, archiveEmailCount — always present.
            static let identity = "identity"
            /// totalElapsedMs, and retrieval/experts/synthesis when known.
            static let timing = "timing"
            /// answerCharCount, citedEmailCount.
            static let output = "output"
            /// totalFindings, highRelevanceCount, findingsLinkedToEmails.
            static let findings = "findings"
            /// kgNodesCited.
            static let knowledgeGraph = "knowledgeGraph"
            /// expertsRun, subQueryCount, toolsUsed.
            static let routing = "routing"
            /// synthesisLayerCount, contextChars.
            static let compression = "compression"
        }

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

    /// Rolling averages over the last N records.
    ///
    /// Each metric is averaged ONLY over the records whose engine reported
    /// that field group, and carries the size of that subset. A metric with
    /// `samples == 0` was not measured; it is not a value of zero.
    func summary(lastN: Int = 50) -> Summary {
        let slice = Array(recent.prefix(lastN))
        guard !slice.isEmpty else { return Summary() }

        func average(_ group: String, _ value: (QueryRecord) -> Double) -> Measured {
            let reporting = slice.filter { $0.reported.contains(group) }
            guard !reporting.isEmpty else { return Measured() }
            return Measured(
                value: reporting.map(value).reduce(0, +) / Double(reporting.count),
                samples: reporting.count)
        }

        let count = Double(slice.count)
        return Summary(
            sampleSize: slice.count,
            elapsedMs: average(QueryRecord.Group.timing) { Double($0.totalElapsedMs) },
            findings: average(QueryRecord.Group.findings) { Double($0.totalFindings) },
            highRelevance: average(QueryRecord.Group.findings) { Double($0.highRelevanceCount) },
            citedEmails: average(QueryRecord.Group.output) { Double($0.citedEmailCount) },
            kgNodes: average(QueryRecord.Group.knowledgeGraph) { Double($0.kgNodesCited) },
            // Failure and fallback are recorded by every path, so these are
            // over the whole slice.
            fallbackRate: Double(slice.filter { $0.fallbackUsed }.count) / count,
            failureRate: Double(slice.filter { $0.didFail }.count) / count,
            byEngine: Dictionary(grouping: slice, by: \.intent).mapValues(\.count)
        )
    }

    /// An average and the number of records it came from. `samples == 0` means
    /// no engine in the window measured it.
    struct Measured: Equatable {
        var value: Double = 0
        var samples: Int = 0
        var isMeasured: Bool { samples > 0 }
        /// For display: the value, or an explicit "not measured".
        func description(_ format: String = "%.1f") -> String {
            isMeasured ? String(format: format, value) + " (n=\(samples))" : "not measured"
        }
    }

    struct Summary {
        var sampleSize: Int = 0
        var elapsedMs: Measured = Measured()
        var findings: Measured = Measured()
        var highRelevance: Measured = Measured()
        var citedEmails: Measured = Measured()
        var kgNodes: Measured = Measured()
        var fallbackRate: Double = 0
        var failureRate: Double = 0
        /// Query count per engine, so a summary is never read as if one engine
        /// produced all of it.
        var byEngine: [String: Int] = [:]
    }
}
