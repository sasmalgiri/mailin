@testable import ArchiveCore
//
//  ITAdminStatsEngine.swift
//  maxmailin
//
//  §3-A9 (switch: `v3AnalysisQueries`). IT Admin's batch figures over the
//  WHOLE archive in one pass: SPF/DKIM/DMARC pass counts (same header test as
//  the view), sending domains, mail clients, TLS, attachments, and the threat
//  buckets with the highest-risk emails (ThreatScoring — the view's rule as a
//  pure function). Only counts and the ten highest-risk headers are kept.
//

import Foundation

struct ITAdminWholeStats: Sendable {
    var total = 0
    var spfPass = 0, dkimPass = 0, dmarcPass = 0, tls = 0
    var domains: [(String, Int)] = []
    var clients: [(String, Int)] = []
    var emailsWithAttachments = 0, attachments = 0
    var high = 0, medium = 0, low = 0, clean = 0
    var highRisk: [(email: MBOXParser.RawEmail, score: Int)] = []
}

@MainActor
enum ITAdminStatsEngine {
    private struct Progress: Codable, Sendable { var emails = 0 }

    static func compute(query: EmailQuery = .all) async throws -> (stats: ITAdminWholeStats, receipt: ScopeJobReceipt) {
        var s = ITAdminWholeStats()
        var domains: [String: Int] = [:], clients: [String: Int] = [:]
        var top: [(MBOXParser.RawEmail, Int)] = []
        let result = try await ScopeJob.run(
            key: "itadmin.stats", title: String(localized: "IT security statistics"),
            capability: .v3AnalysisQueries, query: query, resumable: false, initialState: Progress()
        ) { state, batch in
            for email in batch {
                s.total += 1
                let auth = (email.headers["Authentication-Results"] ?? email.headers["authentication-results"] ?? "").lowercased()
                if auth.contains("spf=pass") { s.spfPass += 1 }
                if auth.contains("dkim=pass") { s.dkimPass += 1 }
                if auth.contains("dmarc=pass") { s.dmarcPass += 1 }
                if email.headers.contains(where: { k, v in
                    k.lowercased().hasPrefix("received") && (v.lowercased().contains("tls") || v.lowercased().contains("esmtps"))
                }) { s.tls += 1 }
                let from = (email.headers["From"] ?? "").replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
                if let at = from.lastIndex(of: "@") {
                    let d = String(from[from.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !d.isEmpty { domains[d, default: 0] += 1 }
                }
                if let client = email.headers["X-Mailer"] ?? email.headers["User-Agent"] { clients[client, default: 0] += 1 }
                if !email.attachments.isEmpty { s.emailsWithAttachments += 1 }
                s.attachments += email.attachments.count
                let score = ThreatScoring.score(email)
                switch score {
                case 7...: s.high += 1
                case 4..<7: s.medium += 1
                case 1..<4: s.low += 1
                default: s.clean += 1
                }
                if score >= 7 {
                    var light = email
                    light.plainBody = ""; light.htmlBody = ""; light.rawSource = ""; light.mimeRoot = nil; light.isBodyCompacted = true
                    top.append((light, score))
                    if top.count > 50 { top.sort { $0.1 > $1.1 }; top.removeLast(top.count - 10) }
                }
            }
            state.emails += batch.count
        }
        s.domains = domains.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        s.clients = clients.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        s.highRisk = top.sorted { $0.1 > $1.1 }.prefix(10).map { (email: $0.0, score: $0.1) }
        return (s, result.receipt)
    }
}
