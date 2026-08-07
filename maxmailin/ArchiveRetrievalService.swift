//
//  ArchiveRetrievalService.swift
//  maxmailin
//
//  Stage 5 W3 / AI substrate cutover (v2-core-cutover): the bounded, FTS5-backed
//  replacement for `EmailSearchIndex`'s in-RAM retrieval.
//
//  The legacy `EmailSearchIndex` builds a whole-corpus in-RAM index (keyword maps
//  + per-email sentence-embedding vectors) at import, so retrieval memory scaled
//  with the archive. This service instead asks SQLite FTS5 for the top-`limit`
//  bm25 candidates, hydrates only those from the store, and returns the same
//  `EmailNLPEngine.SearchResult` shape the AI layer already consumes — so peak
//  memory is bounded by `limit`, regardless of archive size.
//
//  Tradeoff (owner smoke-test): FTS5 provides keyword/bm25 relevance, not the
//  legacy sentence-embedding vector similarity. Ranking may differ from the old
//  hybrid for semantically-phrased queries; correctness of *which* emails are
//  retrievable is preserved and bounded.
//

import Foundation

@MainActor
final class ArchiveRetrievalService {

    static let shared = ArchiveRetrievalService(data: .shared, fts: .shared)

    private let data: ArchiveDataService
    private let fts: FTSSearchIndex
    init(data: ArchiveDataService, fts: FTSSearchIndex) {
        self.data = data
        self.fts = fts
    }

    /// Bounded relevance retrieval: FTS5 bm25 candidate IDs → hydrate → results,
    /// preserving bm25 rank order. Never materializes the corpus.
    func retrieve(_ query: String, limit: Int = 15) async throws -> [EmailNLPEngine.SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let ids = try await fts.search(trimmed, limit: limit)
        guard !ids.isEmpty else { return [] }
        let emails = try await data.fullEmails(ids: ids)
        let byID = Dictionary(emails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var results: [EmailNLPEngine.SearchResult] = []
        results.reserveCapacity(ids.count)
        for (rank, id) in ids.enumerated() {
            guard let email = byID[id] else { continue }
            // Descending score preserves the bm25 order the store returned.
            let score = Double(ids.count - rank)
            results.append(EmailNLPEngine.SearchResult(email: email, score: score, matchContext: Self.snippet(email)))
        }
        return results
    }

    /// Convenience for callers that already tokenized into terms.
    func retrieve(terms: [String], limit: Int = 15) async throws -> [EmailNLPEngine.SearchResult] {
        try await retrieve(terms.joined(separator: " "), limit: limit)
    }

    // MARK: - Bounded thread expansion (replaces EmailSearchIndex.expandByThread)

    /// Expand a bounded seed set with same-thread emails via bounded FTS
    /// subject lookups + hydrated Message-ID/References matching — never a
    /// whole-archive scan, hard-capped at `cap` results.
    func expandThread(_ seeds: [MBOXParser.RawEmail], cap: Int = 50) async -> [MBOXParser.RawEmail] {
        guard !seeds.isEmpty else { return [] }
        guard seeds.count < cap else { return Array(seeds.prefix(cap)) }

        var subjects: [String] = []
        var messageIDs = Set<String>()
        for email in seeds {
            if let subject = email.headers["Subject"] {
                let cleaned = Self.normalizedSubject(subject)
                if cleaned.count >= 3 && !subjects.contains(cleaned) { subjects.append(cleaned) }
            }
            if let msgID = email.headers["Message-ID"] { messageIDs.insert(msgID.trimmingCharacters(in: .whitespaces)) }
            if let inReply = email.headers["In-Reply-To"], !inReply.isEmpty {
                messageIDs.insert(inReply.trimmingCharacters(in: .whitespaces))
            }
            if let refs = email.headers["References"] {
                for ref in refs.components(separatedBy: " ") where ref.contains("@") {
                    messageIDs.insert(ref.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        var expanded = seeds
        var seen = Set(seeds.map(\.id))
        for subject in subjects.prefix(5) {
            guard expanded.count < cap else { break }
            let ids = (try? await fts.searchRaw(FTSQueryBuilder.escapeTerm(subject), limit: 20)) ?? []
            let fresh = ids.filter { !seen.contains($0) }
            guard !fresh.isEmpty else { continue }
            let candidates = (try? await data.fullEmails(ids: Array(fresh.prefix(cap - expanded.count)))) ?? []
            for candidate in candidates {
                guard expanded.count < cap else { break }
                guard !seen.contains(candidate.id) else { continue }
                let sameSubject = Self.normalizedSubject(candidate.headers["Subject"] ?? "") == subject
                let sameReferences: Bool = {
                    if let inReply = candidate.headers["In-Reply-To"],
                       messageIDs.contains(inReply.trimmingCharacters(in: .whitespaces)) { return true }
                    if let refs = candidate.headers["References"] {
                        return refs.components(separatedBy: " ")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .contains(where: { messageIDs.contains($0) })
                    }
                    return false
                }()
                if sameSubject || sameReferences {
                    expanded.append(candidate)
                    seen.insert(candidate.id)
                }
            }
        }
        return expanded
    }

    private static func normalizedSubject(_ subject: String) -> String {
        subject
            .replacingOccurrences(of: "Re: ", with: "")
            .replacingOccurrences(of: "Fwd: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func snippet(_ email: MBOXParser.RawEmail) -> String {
        let body = email.plainBody.isEmpty ? (email.headers["Subject"] ?? "") : email.plainBody
        return String(body.prefix(160))
    }
}
