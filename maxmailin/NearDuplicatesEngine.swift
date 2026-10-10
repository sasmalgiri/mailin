@testable import ArchiveCore
//
//  NearDuplicatesEngine.swift
//  maxmailin
//
//  §3-A4 (switch: `v3NearDuplicates`, requires the per-email analysis
//  index). Near-duplicates across the WHOLE archive, defensibly:
//
//   1. Candidates: emails sharing a MinHash LSH band bucket (16 bands × 4
//      rows over word 5-shingles, stored per email by the feature index).
//      Bands only choose what to compare — they never decide a result.
//   2. Verification: exact Jaccard similarity of the two emails' shingle
//      sets; a pair counts only at or above the threshold.
//   3. Groups: verified pairs joined transitively (union–find); the oldest
//      member by id order is the representative; the group's score is its
//      weakest verified link.
//   4. Recorded: threshold, shingle size, bands × rows, emails covered and
//      index coverage go into the receipt; findings are persisted (algorithm
//      version 101) so reopening pages them. Groups are listed, never deleted.
//
//  Emails the index has not analysed yet cannot be candidates; the result
//  says how many of the archive's emails were covered.
//

import Foundation

@MainActor
enum NearDuplicatesEngine {
    static let algoVersion = 101

    struct Result {
        var groups: Int
        var verifiedPairs: Int
        var candidatePairs: Int
        var indexed: Int
        var total: Int
        var receiptFields: [CapturedDocument.Field]
    }

    static func run(threshold: Double) async throws -> Result {
        let store = SQLiteEmailStore.shared
        let token = EngineGuard.begin(.v3NearDuplicates)
        defer { EngineGuard.end(token) }
        let started = Date()
        let coverage = try await store.featureCoverage(version: FeatureExtractor.version)

        var parent: [UUID: UUID] = [:]
        func find(_ x: UUID) -> UUID {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if ra.uuidString < rb.uuidString { parent[rb] = ra } else { parent[ra] = rb }
        }
        var weakest: [UUID: Double] = [:]   // keyed by member, folded into roots at the end
        var candidates = 0, verified = 0
        var cursor: (UUID, UUID)?
        var shingleCache: [UUID: Set<UInt64>] = [:]

        while true {
            try Task.checkCancellation()
            let pairs = try await store.minhashCandidatePairs(after: cursor, limit: 2_000)
            if pairs.isEmpty { break }
            cursor = pairs.last
            candidates += pairs.count
            // Shingles for this page's emails only.
            let needed = Set(pairs.flatMap { [$0.0, $0.1] }).filter { shingleCache[$0] == nil }
            var start = 0
            let neededList = Array(needed)
            while start < neededList.count {
                let chunk = Array(neededList[start..<min(start + 200, neededList.count)])
                let emails = try await ArchiveDataService.shared.fullEmails(ids: chunk)
                let computed = await Task.detached(priority: .userInitiated) {
                    emails.map { email -> (UUID, Set<UInt64>) in
                        let text = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
                        return (email.id, MinHash.shingles(of: text))
                    }
                }.value
                for (id, set) in computed { shingleCache[id] = set }
                start += chunk.count
            }
            for (a, b) in pairs {
                guard let sa = shingleCache[a], let sb = shingleCache[b], !sa.isEmpty, !sb.isEmpty else { continue }
                let j = MinHash.jaccard(sa, sb)
                guard j >= threshold else { continue }
                verified += 1
                if parent[a] == nil { parent[a] = a }
                if parent[b] == nil { parent[b] = b }
                union(a, b)
                weakest[a] = min(weakest[a] ?? 1, j)
                weakest[b] = min(weakest[b] ?? 1, j)
            }
            // Keep the cache bounded to the current neighbourhood: pairs are
            // ordered by the first email, so earlier firsts never return.
            if shingleCache.count > 20_000, let first = pairs.last?.0 {
                shingleCache = shingleCache.filter { $0.key.uuidString >= first.uuidString }
            }
            await Task.yield()
        }

        var members: [UUID: [UUID]] = [:]
        for id in parent.keys { members[find(id), default: []].append(id) }
        var rows: [SQLiteEmailStore.NearDupMemberRow] = []
        var groupCount = 0
        for (root, ids) in members where ids.count > 1 {
            groupCount += 1
            let score = ids.compactMap { weakest[$0] }.min() ?? threshold
            let key = root.uuidString
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                rows.append(.init(groupKey: key, emailID: id, isRepresentative: id == root, similarity: score))
            }
        }
        let revision = (try? await store.corpusRevision()) ?? 0
        try await store.nearDuplicatesReplace(rows, algoVersion: algoVersion, corpusRevision: revision)

        let f = ISO8601DateFormatter()
        let fields: [CapturedDocument.Field] = [
            .init(key: "Method", value: "MinHash LSH candidates, exact Jaccard verification"),
            .init(key: "Similarity threshold", value: String(format: "%.2f", threshold)),
            .init(key: "Shingles", value: "word \(MinHash.shingleSize)-grams"),
            .init(key: "LSH bands × rows", value: "\(MinHash.bandsCount) × \(MinHash.rowsPerBand)"),
            .init(key: "Emails in archive", value: "\(coverage.total)"),
            .init(key: "Emails indexed (could be compared)", value: "\(coverage.indexed)"),
            .init(key: "Candidate pairs", value: "\(candidates)"),
            .init(key: "Verified pairs", value: "\(verified)"),
            .init(key: "Groups", value: "\(groupCount)"),
            .init(key: "Archive revision", value: "\(revision)"),
            .init(key: "Started", value: f.string(from: started)),
            .init(key: "Finished", value: f.string(from: Date())),
        ]
        ForensicManager.shared.logAction("Near-Duplicate Detection",
            detail: "\(groupCount) groups from \(verified) verified of \(candidates) candidate pairs; threshold \(threshold); \(coverage.indexed) of \(coverage.total) emails indexed")
        return Result(groups: groupCount, verifiedPairs: verified, candidatePairs: candidates,
                      indexed: coverage.indexed, total: coverage.total, receiptFields: fields)
    }
}
