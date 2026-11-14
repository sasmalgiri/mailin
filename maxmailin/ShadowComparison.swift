@testable import ArchiveCore
//
//  ShadowComparison.swift
//  maxmailin
//
//  §3-M4. Debug and TestFlight builds only: runs the previous engine and the
//  3.0 engine of a tool on the SAME emails and records every difference in
//  the result, as evidence for promotion (M5).
//
//  The shared set is the newest N emails of the archive (≤ 2,000, the old
//  engines' working-set size): the 3.0 engine gets it as a query
//  (`newestLimit`), the previous engine gets the same emails as an array —
//  the way it always worked. Only read-only tools are compared, so a run
//  changes no data. Each tool states the differences that are expected by
//  design (e.g. the 3.0 duplicate finder also matches the EDRM MIH); any
//  other difference is reported as a mismatch.
//
//  Reports are appended to Application Support/mailin/ShadowComparison.jsonl
//  (one JSON object per tool per run) and shown in Settings ▸ Modules.
//

import Foundation
import StoreKit

@MainActor
enum ShadowComparison {
    /// The old engines' working-set size.
    nonisolated static let maxSubset = 2_000

    struct Report: Codable, Sendable, Identifiable {
        var id: String { tool + "@" + ISO8601DateFormatter().string(from: date) }
        let tool: String
        let date: Date
        let appVersion: String
        let subset: Int
        let previous: [String: Int]
        let current: [String: Int]
        /// Keys whose values differ, as "key: previous → 3.0".
        let differences: [String]
        /// Differences the 3.0 engine makes on purpose.
        let expected: String?
        var matches: Bool { differences.isEmpty }
    }

    struct Pair {
        let tool: String
        let capability: Capability
        let expected: String?
        let previous: ([MBOXParser.RawEmail]) -> [String: Int]
        let current: (EmailQuery) async throws -> [String: Int]
    }

    /// Debug builds, and TestFlight / Xcode-installed builds. Never the App Store.
    static func isAvailable() async -> Bool {
        #if DEBUG
        return true
        #else
        guard let verified = try? await AppTransaction.shared,
              case .verified(let transaction) = verified else { return false }
        return transaction.environment != .production
        #endif
    }

    static let keywordsForComparison: [KeywordMonitor.WatchedKeyword] = [
        .init(keyword: "confidential"), .init(keyword: "invoice"), .init(keyword: "password"),
        .init(keyword: "urgent"), .init(keyword: #"\b\d{4}-\d{4}\b"#, isRegex: true),
    ]

    static var pairs: [Pair] {
        [
            Pair(tool: String(localized: "PII report"), capability: .v3PIIReport, expected: nil,
                 previous: { emails in
                     let found = EmailNLPEngine.detectPII(in: emails)
                     var out = Dictionary(grouping: found, by: { $0.type.rawValue }).mapValues(\.count)
                     out["emails with PII"] = Set(found.map(\.emailID)).count
                     return out
                 },
                 current: { query in
                     let r = try await PIIEngine.scan(scope: ArchiveScope(query: query, total: nil, loaded: nil))
                     var out = Dictionary(uniqueKeysWithValues: r.counts.map { ($0.key.rawValue, $0.value) })
                     out["emails with PII"] = r.emailsWithPII
                     return out
                 }),
            Pair(tool: String(localized: "NLP classification"), capability: .v3EDiscovery, expected: nil,
                 previous: { emails in
                     Dictionary(uniqueKeysWithValues: EmailNLPEngine.classifyAll(emails).map { ($0.key.rawValue, $0.value) })
                 },
                 current: { query in
                     let (rows, _) = try await EDiscoveryEngine.classify(scope: ArchiveScope(query: query, total: nil, loaded: nil))
                     return Dictionary(uniqueKeysWithValues: rows.map { ($0.category.rawValue, $0.count) })
                 }),
            Pair(tool: String(localized: "Indicator extraction"), capability: .v3IOC,
                 expected: String(localized: "3.0 removes the same indicator found in different batches once (by type and value, ignoring case)."),
                 previous: { emails in
                     Dictionary(grouping: IOCExtractor.extract(from: emails), by: { $0.type.rawValue }).mapValues(\.count)
                 },
                 current: { query in
                     let (entries, _) = try await IOCEngine.extract(scope: ArchiveScope(query: query, total: nil, loaded: nil))
                     return Dictionary(grouping: entries, by: { $0.type.rawValue }).mapValues(\.count)
                 }),
            Pair(tool: String(localized: "Keyword sweep"), capability: .v3KeywordMonitor, expected: nil,
                 previous: { emails in
                     let m = KeywordMonitor.scan(emails: emails, keywords: keywordsForComparison)
                     var out = Dictionary(grouping: m, by: { $0.keyword.keyword }).mapValues(\.count)
                     out["matched emails"] = Set(m.map(\.email.id)).count
                     return out
                 },
                 current: { query in
                     let (m, _) = try await KeywordMonitorEngine.scan(scope: ArchiveScope(query: query, total: nil, loaded: nil),
                                                                       keywords: keywordsForComparison)
                     var out = Dictionary(grouping: m, by: { $0.keyword.keyword }).mapValues(\.count)
                     out["matched emails"] = Set(m.map(\.email.id)).count
                     return out
                 }),
            Pair(tool: String(localized: "Exact duplicates"), capability: .v3Duplicates,
                 expected: String(localized: "3.0 also groups the same message imported from different sources (EDRM MIH, §3-Q3): more groups are possible, never fewer."),
                 previous: { emails in
                     let groups = DuplicateManagerView.findExactDuplicates(in: emails)
                     return ["groups": groups.count, "emails in groups": groups.reduce(0) { $0 + $1.count }]
                 },
                 current: { query in
                     let (groups, _) = try await DuplicatesEngine.exactGroups(query: query)
                     return ["groups": groups.count, "emails in groups": groups.reduce(0) { $0 + $1.count }]
                 }),
        ]
    }

    /// Keys whose values differ.
    nonisolated static func differences(previous: [String: Int], current: [String: Int]) -> [String] {
        Set(previous.keys).union(current.keys).sorted().compactMap { key in
            let a = previous[key] ?? 0, b = current[key] ?? 0
            return a == b ? nil : "\(key): \(a) → \(b)"
        }
    }

    /// Runs every pair on the newest `subset` emails and appends the reports.
    static func run(subset requested: Int = maxSubset) async throws -> [Report] {
        let subset = max(1, min(requested, maxSubset))
        var query = EmailQuery()
        query.newestLimit = subset
        // The same emails for the previous engines, loaded the way they were.
        var emails: [MBOXParser.RawEmail] = []
        for try await page in ScopeJobEnvironment.archive.streamSummaries(query: query, batchSize: 500) {
            emails += try await ScopeJobEnvironment.archive.fullEmails(ids: page.map(\.id))
        }
        var reports: [Report] = []
        for pair in pairs {
            try Task.checkCancellation()
            let previous = pair.previous(emails)
            let current = try await pair.current(query)
            reports.append(Report(tool: pair.tool, date: Date(), appVersion: EngineGuard.appVersion, subset: emails.count,
                                  previous: previous, current: current,
                                  differences: differences(previous: previous, current: current),
                                  expected: pair.expected))
        }
        append(reports)
        return reports
    }

    static var reportURL: URL {
        if let root = ScopeJobEnvironment.current?.root { return root.appendingPathComponent("ShadowComparison.jsonl") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("mailin/ShadowComparison.jsonl")
    }

    private static func append(_ reports: [Report]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let text = reports.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        let url = reportURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url, options: .atomic)   // lint:allow private test-build report, not a user file
        }
    }

    /// Every report recorded so far (oldest first).
    static func recorded() -> [Report] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? String(contentsOf: reportURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { try? dec.decode(Report.self, from: Data($0.utf8)) }
    }
}

// MARK: - Panel (Settings ▸ Modules; Debug and TestFlight builds only)

import SwiftUI

struct ShadowComparisonPanel: View {
    @State private var available = false
    @State private var running = false
    @State private var reports: [ShadowComparison.Report] = []
    @State private var failure: String?

    var body: some View {
        // A view that is always there: `.task` on an empty Group never runs,
        // so the content it loads could never appear.
        VStack(alignment: .leading, spacing: 0) {
            if available {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compare with the previous engines")
                        .font(.subheadline.weight(.semibold))
                    Text("Runs the previous and the 3.0 engine of five read-only tools on the newest \(ShadowComparison.maxSubset) emails and lists every difference. Test builds only; nothing is changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(running ? String(localized: "Comparing…") : String(localized: "Compare")) { compare() }
                            .disabled(running)
                        if running { ProgressView().controlSize(.small) }
                        if !reports.isEmpty {
                            Text("\(reports.filter(\.matches).count) of \(reports.count) tools match")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let failure {
                        Text("The comparison could not run: \(failure)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(reports) { report in
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(report.tool).font(.callout.weight(.medium))
                            } icon: {
                                Image(systemName: report.matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(report.matches ? .green : .orange)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(report.matches ? String(localized: "Matches") : String(localized: "Differs"))
                            if report.matches {
                                Text("Matches").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Differs: \(report.differences.joined(separator: "; "))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let expected = report.expected {
                                    Text("Expected: \(expected)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task { available = await ShadowComparison.isAvailable() }
    }

    private func compare() {
        running = true
        failure = nil
        Task { @MainActor in
            defer { running = false }
            do { reports = try await ShadowComparison.run() } catch { failure = error.localizedDescription }
        }
    }
}
