@testable import ArchiveCore
//
//  PredictiveInsightsEngine.swift
//  maxmailin
//
//  §3-A3 (switch: `v3AnalysisQueries`).
//
//  Whole-archive predictive insights:
//   • Security forecast — phishing, PII and anomaly figures over EVERY email
//     (the previous forecast described only the newest 5,000).
//   • Urgency — every email is scored with the same rules; the strongest
//     1,000 are kept (headers only) for the list, with the total stated.
//   • Thread outcomes — still the most recent window: an outcome is about
//     where a conversation is heading now, so recent activity is the right
//     basis (same as before).
//

import Foundation

@MainActor
enum PredictiveInsightsEngine {
    static let keptUrgent = 1_000

    struct Result {
        var summary: PredictiveEngine.PredictionSummary
        var urgentTotal: Int
        var scanned: Int
    }

    private struct Progress: Codable, Sendable { var emails = 0 }

    static func analyze(query: EmailQuery = .all) async throws -> Result {
        var urgent: [PredictiveEngine.UrgencyPrediction] = []
        var urgentTotal = 0
        var highPhishing = 0, medPhishing = 0, piiCount = 0, criticalPII = 0, total = 0
        let result = try await ScopeJob.run(
            key: "predictive.insights", title: String(localized: "Predictive insights"),
            capability: .v3AnalysisQueries, query: query, resumable: false, initialState: Progress()
        ) { state, batch in
            let (u, phish, pii) = await Task.detached(priority: .userInitiated) {
                (PredictiveEngine.predictUrgency(emails: batch),
                 EmailNLPEngine.detectPhishing(in: batch).map(\.riskLevel),
                 EmailNLPEngine.detectPII(in: batch).map(\.contextualRiskScore))
            }.value
            urgentTotal += u.count
            for p in u {
                var light = p.email
                light.plainBody = ""; light.htmlBody = ""; light.rawSource = ""; light.mimeRoot = nil; light.isBodyCompacted = true
                urgent.append(PredictiveEngine.UrgencyPrediction(email: light, urgency: p.urgency, reason: p.reason, score: p.score))
            }
            if urgent.count > keptUrgent * 2 {
                urgent.sort { $0.score > $1.score }
                urgent.removeLast(urgent.count - keptUrgent)
            }
            highPhishing += phish.filter { $0 == .high }.count
            medPhishing += phish.filter { $0 == .medium }.count
            piiCount += pii.count
            criticalPII += pii.filter { $0 > 7.0 }.count
            total += batch.count
            state.emails += batch.count
        }
        urgent.sort { $0.score > $1.score }
        if urgent.count > keptUrgent { urgent.removeLast(urgent.count - keptUrgent) }

        let anomalies = (try? await AnomalyDetectionEngine.detectAnomalies(from: ScopeJobEnvironment.archive)) ?? []
        let security = forecast(total: total, highPhishing: highPhishing, medPhishing: medPhishing,
                                piiCount: piiCount, criticalPII: criticalPII,
                                securityAnomalies: anomalies.filter { $0.type == .newDomain || $0.type == .recipientAnomaly }.count)
        let recent = try await PredictiveEngine.recentWorkingSet(from: ScopeJobEnvironment.archive, query: query)
        let threads = await Task.detached(priority: .userInitiated) { PredictiveEngine.predictThreadOutcomes(emails: recent) }.value
        return Result(summary: .init(urgentEmails: urgent, threadPredictions: threads, securityForecast: security),
                      urgentTotal: urgentTotal, scanned: result.receipt.processed)
    }

    /// The previous forecast's rules, from counts instead of arrays.
    static func forecast(total: Int, highPhishing: Int, medPhishing: Int, piiCount: Int, criticalPII: Int,
                         securityAnomalies: Int) -> PredictiveEngine.SecurityForecast {
        let phishingRate = total == 0 ? 0.0 : Double(highPhishing + medPhishing) / Double(total)
        let phishingTrend: String
        if phishingRate > 0.1 { phishingTrend = "High — \(Int(phishingRate * 100))% of emails flagged" }
        else if phishingRate > 0.03 { phishingTrend = "Moderate — \(highPhishing) high-risk, \(medPhishing) medium-risk" }
        else if highPhishing > 0 { phishingTrend = "Low but present — \(highPhishing) high-risk email(s)" }
        else { phishingTrend = "Clean — no phishing detected" }
        let piiTrend: String
        if criticalPII > 0 { piiTrend = "Critical — \(criticalPII) high-risk PII exposures (SSN, credit card, etc.)" }
        else if piiCount > 5 { piiTrend = "Elevated — \(piiCount) PII findings across archive" }
        else if piiCount > 0 { piiTrend = "Low — \(piiCount) minor PII finding(s)" }
        else { piiTrend = "Clean — no PII detected" }
        let riskLevel: String
        if highPhishing >= 3 || criticalPII >= 2 { riskLevel = "High" }
        else if highPhishing >= 1 || medPhishing >= 5 || criticalPII >= 1 || securityAnomalies >= 3 { riskLevel = "Medium" }
        else if medPhishing >= 1 || piiCount > 0 || securityAnomalies > 0 { riskLevel = "Low" }
        else { riskLevel = "Minimal" }
        var recommendations: [String] = []
        if highPhishing > 0 { recommendations.append("Review \(highPhishing) high-risk phishing email(s) immediately") }
        if criticalPII > 0 { recommendations.append("Address \(criticalPII) critical PII exposure(s) — potential compliance risk") }
        if securityAnomalies > 0 { recommendations.append("Investigate \(securityAnomalies) security anomalies (new domains, unusual recipients)") }
        if phishingRate > 0.05 { recommendations.append("Consider sender verification training — \(Int(phishingRate * 100))% phishing rate is elevated") }
        if recommendations.isEmpty { recommendations.append("No immediate actions required — archive appears clean") }
        return .init(riskLevel: riskLevel, phishingTrend: phishingTrend, piiExposureTrend: piiTrend, recommendations: recommendations)
    }
}
