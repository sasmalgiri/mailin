@testable import ArchiveCore
//
//  PIIEngine.swift
//  maxmailin
//
//  §3-L15 (switch: `v3PIIReport`). The PII report over the WHOLE scope
//  instead of the newest 2,000 (`scanCap`). Same detector
//  (EmailNLPEngine.detectPII), same CSV columns.
//
//  Memory stays flat at any archive size: the scan keeps exact counts per
//  type and the first findings of each type for the screen (the list showed
//  200 per type before too); the CSV export is a second, streamed pass that
//  writes every finding straight to the file.
//

import Foundation

@MainActor
enum PIIEngine {
    static let shownPerType = 200

    struct ScanState: Codable, Sendable {
        var perType = KeyCounter()
        var emailsWithPII = 0
    }

    struct ScanResult {
        var counts: [EmailNLPEngine.PIIType: Int]
        var shown: [EmailNLPEngine.PIIFinding]
        var emailsWithPII: Int
        var receipt: ScopeJobReceipt
        var totalFindings: Int { counts.values.reduce(0, +) }
    }

    static func scan(scope: ArchiveScope) async throws -> ScanResult {
        var shown: [EmailNLPEngine.PIIType: [EmailNLPEngine.PIIFinding]] = [:]
        let result = try await ScopeJob.run(
            key: "pii.scan", title: String(localized: "PII report"),
            capability: .v3PIIReport, query: scope.query, initialState: ScanState()
        ) { state, batch in
            let detected = await Task.detached(priority: .userInitiated) { EmailNLPEngine.detectPII(in: batch) }.value
            state.emailsWithPII += Set(detected.map(\.emailID)).count
            for finding in detected {
                state.perType.add(finding.type.rawValue)
                if shown[finding.type, default: []].count < shownPerType { shown[finding.type, default: []].append(finding) }
            }
        }
        var counts: [EmailNLPEngine.PIIType: Int] = [:]
        for type in EmailNLPEngine.PIIType.allCases {
            let n = result.state.perType.count(of: type.rawValue)
            if n > 0 { counts[type] = n }
        }
        return ScanResult(counts: counts, shown: shown.values.flatMap { $0 },
                          emailsWithPII: result.state.emailsWithPII, receipt: result.receipt)
    }

    /// Every finding in scope, streamed to a CSV (same columns as before).
    static func exportCSV(scope: ArchiveScope) async -> (ExportOutcome, Int) {
        var written = 0
        let (outcome, _) = await PlatformExport.saveStreamed(suggestedName: "mailin_pii_report.csv") { url in
            try await StreamedTextFile.write(to: url) { emit in
                func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                try emit("Type,Value,Risk,Context,Email Subject,Email ID\n")
                let token = EngineGuard.begin(.v3PIIReport)
                defer { EngineGuard.end(token) }
                for try await batch in ArchiveDataService.shared.streamFullEmails(query: scope.query, batchSize: 200) {
                    try Task.checkCancellation()
                    let detected = await Task.detached(priority: .userInitiated) { EmailNLPEngine.detectPII(in: batch) }.value
                    var chunk = ""
                    for finding in detected {
                        chunk += [finding.type.rawValue, finding.value,
                                  String(format: "%.1f", finding.contextualRiskScore),
                                  finding.riskContext.rawValue, finding.emailSubject,
                                  finding.emailID.uuidString].map(esc).joined(separator: ",") + "\n"
                    }
                    written += detected.count
                    try emit(chunk)
                }
            }
        }
        return (outcome, written)
    }
}
