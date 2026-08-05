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
