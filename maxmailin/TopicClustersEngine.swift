@testable import ArchiveCore
//
//  TopicClustersEngine.swift
//  maxmailin
//
//  §3-A5 (switch: `v3TopicClusters`). Topic clusters for the WHOLE archive:
//   1. k-means++ (the existing algorithm) on an evenly spaced sample across
//      the archive — learning topics needs a sample, and the sample is stated;
//   2. every email is then assigned to its nearest cluster centre (cosine on
//      the same sentence embedding of subject + first 300 body characters);
//   3. the topic is persisted per email, so counts, filters and reopening
//      cover the archive.
//  Emails the embedding cannot read (no text) are counted as unassigned.
//

import Foundation
import NaturalLanguage
import SwiftUI

@MainActor
enum TopicClustersEngine {
    struct Result {
        var clusters: [TopicClustersView.TopicCluster]
        var silhouette: Double
        var sampled: Int
        var assigned: Int
        var unassigned: Int
        var receipt: ScopeJobReceipt
    }

    private struct Progress: Codable, Sendable { var emails = 0 }

    nonisolated static func vector(_ email: MBOXParser.RawEmail, _ embedding: NLEmbedding) -> [Double]? {
        embedding.vector(for: (email.headers["Subject"] ?? "") + ". " + String(email.plainBody.prefix(300)))
    }

    nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return (na > 0 && nb > 0) ? dot / (na.squareRoot() * nb.squareRoot()) : -1
    }

    static func run() async throws -> Result {
        let sample = try await ArchiveSample.evenlySpaced()
        let emails = sample.emails
        let k = min(8, max(2, emails.count / 20))
        let (clusters, silhouette, centroids) = await Task.detached(priority: .utility) { () -> ([TopicClustersView.TopicCluster], Double, [[Double]]) in
            let (result, sil) = TopicClustersView.kMeansPlusPlusClustering(emails: emails, k: k)
            guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return (result, sil, []) }
            let byID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
            let centres: [[Double]] = result.map { cluster in
                let vecs = cluster.emailIDs.compactMap { byID[$0] }.compactMap { vector($0, embedding) }
                guard let dim = vecs.first?.count else { return [] }
                var sum = [Double](repeating: 0, count: dim)
                for v in vecs { for i in 0..<dim { sum[i] += v[i] } }
                return sum.map { $0 / Double(vecs.count) }
            }
            return (result, sil, centres)
        }.value
        guard !clusters.isEmpty, centroids.count == clusters.count else {
            throw NSError(domain: "mailin.topics", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Not enough readable text to find topics.")])
        }

        var members = [[UUID]](repeating: [], count: clusters.count)
        var unassigned = 0
        let labels = clusters.map(\.label)
        let result = try await ScopeJob.run(
            key: "topics.assign", title: String(localized: "Assign topics"),
            capability: .v3TopicClusters, query: .all, resumable: false, initialState: Progress()
        ) { state, batch in
            let assigned = await Task.detached(priority: .utility) { () -> [(UUID, Int?)] in
                guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return batch.map { ($0.id, nil) } }
                return batch.map { email in
                    guard let v = vector(email, embedding) else { return (email.id, nil) }
                    var best = 0, bestScore = -2.0
                    for (i, c) in centroids.enumerated() where !c.isEmpty {
                        let s = cosine(v, c)
                        if s > bestScore { bestScore = s; best = i }
                    }
                    return (email.id, best)
                }
            }.value
            var topics: [UUID: String] = [:]
            for (id, index) in assigned {
                if let index { members[index].append(id); topics[id] = labels[index] } else { unassigned += 1 }
            }
            try await SQLiteEmailStore.shared.derivedSetTopics(topics)
            state.emails += batch.count
        }
        let whole = clusters.enumerated().map { i, c in
            TopicClustersView.TopicCluster(label: c.label, keywords: c.keywords, emailIDs: members[i],
                                           color: c.color, coherence: c.coherence)
        }
        return Result(clusters: whole, silhouette: silhouette, sampled: emails.count,
                      assigned: members.reduce(0) { $0 + $1.count }, unassigned: unassigned, receipt: result.receipt)
    }
}
