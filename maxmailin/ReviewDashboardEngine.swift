@testable import ArchiveCore
//
//  ReviewDashboardEngine.swift
//  maxmailin
//
//  §3-A11 (switch: `v3AnalysisQueries`). Forensic Review's coding dashboard
//  over the WHOLE archive: totals from the archive count, the tag
//  distribution from the database's evidence-tag index (one grouped query),
//  the same velocity / ETA rule. The previous dashboard counted only the
//  newest 2,000 emails, so "% coded" was wrong for any larger archive.
//

import Foundation

extension ForensicReviewManager {
    @MainActor
    func computeDashboardWholeArchive() async throws -> CodingDashboard {
        let forensic = ForensicManager.shared
        let total = try await ScopeJobEnvironment.archive.count()
        let counts = try await ScopeJobEnvironment.store.forensicTagCounts()
        var dist: [ForensicManager.EvidenceTag: Int] = [:]
        var coded = 0
        for (raw, n) in counts {
            guard let tag = ForensicManager.EvidenceTag(rawValue: raw), tag != .none else { continue }
            dist[tag] = n
            coded += n
        }
        dist[.none] = max(0, total - coded)
        let stats = forensic.computeReviewerStats()
        let velocity = stats.avgSecondsPerTag > 0 ? 60.0 / stats.avgSecondsPerTag : 0
        let remaining = max(0, total - coded)
        return CodingDashboard(
            totalEmails: total, codedCount: coded, tagDistribution: dist,
            privilegeFlagCount: forensic.privilegeFlags.count, codingVelocity: velocity,
            estimatedCompletionMinutes: velocity > 0 ? Double(remaining) / velocity : 0,
            progress: total > 0 ? Double(coded) / Double(total) : 0)
    }
}
