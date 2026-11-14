@testable import ArchiveCore
//
//  AutomationRulesRunEngine.swift
//  maxmailin
//
//  §3-L10 (switch: `v3AutomationRules`). "Run Rules Now" over the WHOLE
//  scope. Same evaluator (AutomationRulesEngine.evaluate). Matched emails are
//  kept with headers only for the results list, so memory follows the
//  number of matches. The confirmation states the exact count first (rule 4).
//

import Foundation

@MainActor
enum AutomationRulesRunEngine {
    struct Progress: Codable, Sendable { var emails = 0 }

    static func run(scope: ArchiveScope, engine: AutomationRulesEngine)
        async throws -> (results: [UUID: [AutomationAction]], matched: [MBOXParser.RawEmail], receipt: ScopeJobReceipt) {
        var results: [UUID: [AutomationAction]] = [:]
        var matched: [MBOXParser.RawEmail] = []
        let result = try await ScopeJob.run(
            key: "automation.run", title: String(localized: "Run automation rules"),
            capability: .v3AutomationRules, query: scope.query, resumable: false, initialState: Progress()
        ) { state, batch in
            for (id, actions) in engine.applyRules(to: batch) { results[id] = actions }
            for email in batch where results[email.id] != nil {
                var light = email
                light.plainBody = ""; light.htmlBody = ""; light.rawSource = ""
                light.mimeRoot = nil; light.isBodyCompacted = true
                matched.append(light)
            }
            state.emails += batch.count
        }
        return (results, matched, result.receipt)
    }
}
