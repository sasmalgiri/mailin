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

    private static func snippet(_ email: MBOXParser.RawEmail) -> String {
        let body = email.plainBody.isEmpty ? (email.headers["Subject"] ?? "") : email.plainBody
        return String(body.prefix(160))
    }
}
