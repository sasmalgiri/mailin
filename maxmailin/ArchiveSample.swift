@testable import ArchiveCore
//
//  ArchiveSample.swift
//  maxmailin
//
//  §3-A5/A11: an evenly spaced sample across the WHOLE scope, for analyses
//  that read message text in ways that do not reduce to counters (trend
//  narratives, pattern finders, topic modelling). Every email of the scope,
//  oldest to newest, has the same chance of being in the sample — unlike the
//  newest-N window it replaces, which never saw older mail. The sample size
//  and the scope total are always shown (rule 6: real limits are stated).
//

import SwiftUI

@MainActor
enum ArchiveSample {
    nonisolated static let defaultSize = 5_000

    /// Every k-th email in date order, so the sample spans the whole range.
    static func evenlySpaced(query: EmailQuery = .all, size: Int = defaultSize) async throws
        -> (emails: [MBOXParser.RawEmail], total: Int) {
        let data = ScopeJobEnvironment.archive
        let total = try await data.count(query: query)
        guard total > 0, size > 0 else { return ([], total) }
        let stride = max(1, total / size)
        var q = query
        q.sort = .dateAsc
        var out: [MBOXParser.RawEmail] = []
        out.reserveCapacity(min(size, total))
        var index = 0
        // Summaries first (cheap), bodies only for the chosen ones.
        for try await page in data.streamSummaries(query: q, batchSize: 5_000) {
            var chosen: [UUID] = []
            for s in page {
                if index % stride == 0, out.count + chosen.count < size { chosen.append(s.id) }
                index += 1
            }
            if !chosen.isEmpty {
                let emails = try await data.fullEmails(ids: chosen)
                let byID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
                out.append(contentsOf: chosen.compactMap { byID[$0] })
            }
            try Task.checkCancellation()
        }
        return (out, total)
    }
}

/// States what a sampled section is based on.
struct SampleNotice: View {
    let sample: Int
    let total: Int
    var exactParts: String? = nil

    var body: some View {
        if total > sample {
            Label {
                Text(String(localized: "Trends and patterns are based on \(sample.formatted()) emails spread evenly across all \(total.formatted()) in the archive.")
                     + (exactParts.map { " " + $0 } ?? ""))
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "chart.dots.scatter")
            }
            .foregroundStyle(.secondary)
            .padding(Spacing.xSmall)
        }
    }
}
