//
//  AIGroundedAnswer.swift
//  maxmailin
//
//  Stage 5 Wave 2C / Phase 6 (v2-core-cutover): the evidence-grounded answer
//  contract for the archive AI. Every factual finding must cite evidence IDs
//  that were ACTUALLY retrieved (via ArchiveEvidenceService). A post-generation
//  verifier drops any finding that cites unknown/deleted evidence or no evidence
//  at all, and abstains ("not enough evidence") when nothing survives — so the
//  assistant is citation-backed and refuses to invent, rather than claiming
//  "zero hallucinations".
//
//  The verifier is content-agnostic: it validates by evidence ID, so archive
//  text like "IGNORE ALL PREVIOUS INSTRUCTIONS" is treated purely as evidence
//  content and can never turn into an ungrounded, accepted claim.
//

import Foundation

enum EvidenceConfidence: String, Sendable, Equatable, Codable {
    case high, medium, low
}

struct GroundedFinding: Sendable, Equatable, Codable {
    let statement: String
    /// Evidence IDs (email UUID strings) this finding is grounded in.
    let evidenceIDs: [String]
    var confidence: EvidenceConfidence
}

struct GroundedAnswer: Sendable, Equatable, Codable {
    var summary: String
    var findings: [GroundedFinding]
    var limitations: [String]
    var abstained: Bool

    static let insufficient = GroundedAnswer(
        summary: "Not enough evidence in this archive to answer that confidently.",
        findings: [], limitations: ["No supporting evidence was retrieved."], abstained: true
    )
}

enum EvidenceVerifier {
    struct Report: Sendable, Equatable {
        var answer: GroundedAnswer
        var droppedUnknownEvidence: Int
        var droppedZeroEvidence: Int
    }

    /// Validate a candidate answer against the evidence set actually retrieved.
    /// Findings citing unknown/deleted evidence, or none, are dropped; if nothing
    /// survives, the answer abstains.
    static func validate(_ answer: GroundedAnswer, retrieved: Set<String>) -> Report {
        var kept: [GroundedFinding] = []
        var unknown = 0, zero = 0
        for finding in answer.findings {
            let cited = Set(finding.evidenceIDs)
            if cited.isEmpty { zero += 1; continue }
            if !cited.isSubset(of: retrieved) { unknown += 1; continue }
            kept.append(finding)
        }
        var result = answer
        result.findings = kept
        if unknown > 0 { result.limitations.append("\(unknown) finding(s) citing unretrieved evidence were removed.") }
        if zero > 0 { result.limitations.append("\(zero) finding(s) with no evidence were removed.") }
        if kept.isEmpty {
            result.abstained = true
            if result.summary.isEmpty { result.summary = GroundedAnswer.insufficient.summary }
        }
        return Report(answer: result, droppedUnknownEvidence: unknown, droppedZeroEvidence: zero)
    }

    /// Convenience over the retrieved `EvidenceReference` set.
    static func validate(_ answer: GroundedAnswer, evidence: [EvidenceReference]) -> Report {
        validate(answer, retrieved: Set(evidence.map(\.evidenceID)))
    }
}
