@testable import ArchiveCore
//
//  KeywordMonitorEngine.swift
//  maxmailin
//
//  §3-L17 (switch: `v3KeywordMonitor`). Keyword sweep over the WHOLE scope.
//  Same matcher (KeywordMonitor.scan: substring or regex, case options,
//  subject + body), batch by batch. Matched emails are kept with headers only
//  (bodies dropped after matching — the result rows show sender, subject and
//  the snippet), so memory follows the number of matches, not the archive.
//
//  Not an FTS pre-filter on purpose: the full-text index tokenises and
//  stems, the monitor matches substrings, so a pre-filter would silently
//  drop matches ("pay" inside "repayment").
//

import Foundation

@MainActor
enum KeywordMonitorEngine {
    struct Progress: Codable, Sendable { var emails = 0 }

    static func scan(scope: ArchiveScope, keywords: [KeywordMonitor.WatchedKeyword])
        async throws -> (matches: [KeywordMonitor.KeywordMatch], receipt: ScopeJobReceipt) {
        var matches: [KeywordMonitor.KeywordMatch] = []
        let result = try await ScopeJob.run(
            key: "keywords.scan", title: String(localized: "Keyword sweep"),
            capability: .v3KeywordMonitor, query: scope.query, resumable: false, initialState: Progress()
        ) { state, batch in
            let found = await Task.detached(priority: .userInitiated) {
                KeywordMonitor.scan(emails: batch, keywords: keywords).map { match -> KeywordMonitor.KeywordMatch in
                    var light = match.email
                    light.plainBody = ""
                    light.htmlBody = ""
                    light.rawSource = ""
                    light.mimeRoot = nil
                    light.isBodyCompacted = true
                    return KeywordMonitor.KeywordMatch(id: match.id, keyword: match.keyword, email: light,
                                                       matchCount: match.matchCount, contextSnippet: match.contextSnippet)
                }
            }.value
            matches.append(contentsOf: found)
            state.emails += batch.count
        }
        return (matches, result.receipt)
    }
}
