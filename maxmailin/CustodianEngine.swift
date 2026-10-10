@testable import ArchiveCore
//
//  CustodianEngine.swift
//  maxmailin
//
//  §3-L8 (switch: `v3Custodians`). Custodian actions over the whole archive:
//  Place All on Hold and Verify Seals cover every email of the custodian
//  (not only those among the newest 2,000), Assign covers every email in the
//  chosen group, and the report's totals and date ranges cover the archive.
//  Same seal rule and same report layout as before.
//

import Foundation

@MainActor
enum CustodianEngine {
    static let unassignedKey = "__unassigned__"

    /// Ids of the group: a custodian's emails, every unassigned email, or
    /// (nil) the whole archive. Ids only — never full emails.
    static func ids(for group: String?) async throws -> [UUID] {
        let manager = ScopeJobEnvironment.custodians
        if let group, group != unassignedKey { return manager.emailIDs(for: group) }
        var out: [UUID] = []
        for try await page in ScopeJobEnvironment.archive.streamSummaries(query: .all, batchSize: 5_000) {
            for s in page where group == nil || manager.custodian(for: s.id) == nil { out.append(s.id) }
        }
        return out
    }

    /// Holds + set-once seals on every email of `custodian`, in batches.
    static func holdAll(custodian: String) async throws -> (held: Int, total: Int) {
        let manager = ScopeJobEnvironment.custodians
        let ids = manager.emailIDs(for: custodian)
        let token = EngineGuard.begin(.v3Custodians)
        defer { EngineGuard.end(token) }
        let before = manager.legalHolds.count
        var start = 0
        while start < ids.count {
            try Task.checkCancellation()
            let chunk = Array(ids[start..<min(start + 1_000, ids.count)])
            let emails = try await ScopeJobEnvironment.archive.fullEmails(ids: chunk)
            manager.placeLegalHoldBatched(emails)
            start += chunk.count
        }
        let held = manager.legalHolds.count - before
        ScopeJobEnvironment.logAction("Legal Hold Placed",
                                         detail: "Legal hold placed on \(held) emails of custodian \(custodian) (\(ids.count) assigned) with evidence seals")
        return (held, ids.count)
    }

    struct SealResult {
        var intact = 0, broken = 0, unsealed = 0
        var verdicts: [UUID: CustodianManager.SealVerification] = [:]
    }

    /// Verifies the seal of every HELD email in the group.
    static func verifySeals(group: String?) async throws -> SealResult {
        let manager = ScopeJobEnvironment.custodians
        let token = EngineGuard.begin(.v3Custodians)
        defer { EngineGuard.end(token) }
        let held: [UUID]
        if let group, group != unassignedKey {
            held = manager.emailIDs(for: group).filter { manager.isUnderLegalHold($0) }
        } else if group == nil {
            held = Array(manager.legalHolds)
        } else {
            held = try await ids(for: group).filter { manager.isUnderLegalHold($0) }
        }
        var result = SealResult()
        var start = 0
        while start < held.count {
            try Task.checkCancellation()
            let chunk = Array(held[start..<min(start + 500, held.count)])
            for email in try await ScopeJobEnvironment.archive.fullEmails(ids: chunk) {
                let verdict = manager.verifyEvidenceSeal(email)
                switch verdict {
                case .intact: result.intact += 1
                case .tampered: result.broken += 1
                case .noSeal: result.unsealed += 1
                case .notHeld: continue
                }
                result.verdicts[email.id] = verdict
            }
            start += chunk.count
        }
        ScopeJobEnvironment.logAction(
            "Evidence Seals Verified",
            detail: "\(result.verdicts.count) checked — \(result.intact) intact, \(result.broken) broken, \(result.unsealed) unsealed (whole archive)")
        return result
    }

    /// Assigns `name` to every email of the group.
    static func assign(_ name: String, group: String?) async throws -> Int {
        let token = EngineGuard.begin(.v3Custodians)
        defer { EngineGuard.end(token) }
        if group == nil, ScopeJobEnvironment.legalMirror.isOn, ScopeJobEnvironment.legalMirror.isActive {
            return try await ScopeJobEnvironment.legalMirror.assignCustodian(name, query: .all)
        }
        let ids = try await ids(for: group)
        ScopeJobEnvironment.custodians.assignCustodian(name, to: ids)
        return ids.count
    }

    /// Emails in the archive with no custodian (exact).
    static func unassignedCount() async -> Int {
        if ScopeJobEnvironment.legalMirror.isOn, ScopeJobEnvironment.legalMirror.isActive,
           let n = try? await ScopeJobEnvironment.store.unassignedCustodianCount() { return n }
        return (try? await ids(for: unassignedKey).count) ?? 0
    }

    /// The custodian report with whole-archive totals — same layout as before.
    static func report() async throws -> String {
        let manager = ScopeJobEnvironment.custodians
        let token = EngineGuard.begin(.v3Custodians)
        defer { EngineGuard.end(token) }
        struct Totals { var emails = 0, held = 0; var first: Date?, last: Date? }
        var totals: [String: Totals] = [:]
        var unassigned = 0
        if ScopeJobEnvironment.legalMirror.isOn, ScopeJobEnvironment.legalMirror.isActive {
            for t in try await ScopeJobEnvironment.store.custodianTotals() {
                totals[t.custodian] = Totals(emails: t.emails, held: t.held, first: t.firstDate, last: t.lastDate)
            }
            unassigned = try await ScopeJobEnvironment.store.unassignedCustodianCount()
        } else {
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: .all, batchSize: 5_000) {
                for s in page {
                    guard let c = manager.custodian(for: s.id) else { unassigned += 1; continue }
                    var t = totals[c] ?? Totals()
                    t.emails += 1
                    if manager.isUnderLegalHold(s.id) { t.held += 1 }
                    t.first = min(t.first ?? s.date, s.date)
                    t.last = max(t.last ?? s.date, s.date)
                    totals[c] = t
                }
            }
        }
        var report = "Custodian Report\n"
        report += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        report += String(repeating: "=", count: 60) + "\n\n"
        for custodian in manager.allCustodians {
            let t = totals[custodian] ?? Totals()
            report += "Custodian: \(custodian)\n"
            report += "  Emails: \(t.emails)\n"
            report += "  Legal Holds: \(t.held)\n"
            report += "  Date Range: \(t.first?.description ?? "N/A") — \(t.last?.description ?? "N/A")\n\n"
        }
        if unassigned > 0 { report += "Unassigned: \(unassigned) emails\n" }
        return report
    }
}
