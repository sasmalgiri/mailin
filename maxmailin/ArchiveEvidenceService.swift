//
//  ArchiveEvidenceService.swift
//  maxmailin
//
//  Stage 5 Wave 2A (v2-core-cutover): the canonical bounded evidence boundary
//  for AI, reports and forensic work. Consumers get a small, ranked set of
//  `EvidenceReference`s (id + headers + bounded excerpt) — never a corpus array.
//  This is what the AI tools (Phase 6) retrieve through, so an answer can only
//  cite evidence that was actually returned here.
//

import Foundation

struct EvidenceReference: Sendable, Identifiable, Equatable {
    let id: EmailID
    let messageID: String?
    let subject: String
    let sender: String
    let date: Date
    let excerpt: String
    let hasAttachments: Bool
    /// Stable public identifier the AI cites; validated back against retrieval.
    var evidenceID: String { id.uuidString }
}

@MainActor
final class ArchiveEvidenceService {
    static let shared = ArchiveEvidenceService(archive: .shared)

    private let archive: ArchiveDataService
    let excerptChars: Int

    init(archive: ArchiveDataService, excerptChars: Int = 600) {
        self.archive = archive
        self.excerptChars = max(80, excerptChars)
    }

    /// Bounded, ranked evidence for a query (FTS ranked for text; keyset for
    /// non-text). Hydrates only `limit` bodies for excerpts.
    func evidence(for query: EmailQuery, limit: Int = 12) async throws -> [EvidenceReference] {
        let page = try await archive.page(query: query, cursor: nil, limit: limit)
        return try await references(for: page.summaries)
    }

    /// Evidence for a specific bounded id set.
    func evidence(ids: [EmailID]) async throws -> [EvidenceReference] {
        guard !ids.isEmpty else { return [] }
        let summaries = try await archive.summaries(ids: Array(ids.prefix(200)))
        // Preserve caller order.
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        return try await references(for: ordered)
    }

    /// Chunk-level excerpting over an ALREADY-BOUNDED email set (typically a
    /// retrieval result). Pure function of its input — replaces the legacy
    /// `EmailSearchIndex.chunkSearch`, which lived on the in-RAM corpus index.
    nonisolated static func chunkExcerpts(
        terms: [String],
        in emails: [MBOXParser.RawEmail],
        maxChunksPerEmail: Int = 2,
        limit: Int = 10,
        preferredTypes: [ChunkType]? = nil
    ) -> [(email: MBOXParser.RawEmail, chunk: String, chunkType: ChunkType, score: Double)] {
        guard !terms.isEmpty else { return [] }
        let lowerTerms = terms.map { $0.lowercased() }
        var results: [(email: MBOXParser.RawEmail, chunk: String, chunkType: ChunkType, score: Double)] = []

        for email in emails.prefix(200) {   // hard bound even if a caller regresses
            guard !email.plainBody.isEmpty || !email.htmlBody.isEmpty else { continue }
            let rawEmail = RawEmail(
                headers: email.headers,
                plainBody: email.plainBody.isEmpty ? nil : email.plainBody,
                htmlBody: email.htmlBody.isEmpty ? nil : email.htmlBody,
                attachments: nil
            )
            let typedChunks = EmailChunker.chunkEmail(rawEmail, emailIndex: 0, maxTokensPerChunk: 200)

            var scored: [(chunk: String, chunkType: ChunkType, score: Double)] = []
            for tc in typedChunks {
                let lower = tc.bodyChunk.lowercased()
                var score = 0.0
                var hitCount = 0
                for term in lowerTerms {
                    var tf = 0
                    var searchStart = lower.startIndex
                    while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                        tf += 1
                        searchStart = range.upperBound
                        if tf >= 10 { break }
                    }
                    if tf > 0 {
                        score += Double(tf)
                        hitCount += 1
                    }
                }
                if hitCount > 1 { score *= 1.0 + Double(hitCount - 1) * 0.5 }
                if lower.contains("?") { score *= 1.15 }
                if lower.range(of: #"\d"#, options: .regularExpression) != nil { score *= 1.1 }
                let wordCount = tc.bodyChunk.split(separator: " ").count
                if wordCount >= 15 && wordCount <= 200 { score *= 1.1 }
                if let preferred = preferredTypes, preferred.contains(tc.chunkType) { score *= 2.0 }
                if score > 0 { scored.append((tc.bodyChunk, tc.chunkType, score)) }
            }

            for (chunk, type, score) in scored.sorted(by: { $0.score > $1.score }).prefix(maxChunksPerEmail) {
                results.append((email: email, chunk: chunk, chunkType: type, score: score))
            }
        }

        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func references(for summaries: [EmailSummary]) async throws -> [EvidenceReference] {
        guard !summaries.isEmpty else { return [] }
        let emails = try await archive.fullEmails(ids: summaries.map(\.id))
        let bodyByID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
        return summaries.map { s in
            let email = bodyByID[s.id]
            let body = email.map { $0.plainBody.isEmpty ? $0.htmlBody : $0.plainBody } ?? s.bodyPreview
            return EvidenceReference(
                id: s.id,
                messageID: s.messageID,
                subject: s.subject,
                sender: s.from,
                date: s.date,
                excerpt: String(body.prefix(excerptChars)),
                hasAttachments: s.hasAttachments
            )
        }
    }
}
