@testable import ArchiveCore
//
//  IOCEngine.swift
//  maxmailin
//
//  §3-L16 (switch: `v3IOC`). Indicator extraction over the WHOLE scope.
//  Same extractor as before (IOCExtractor), run batch by batch; indicators
//  are de-duplicated across the whole scope the same way the extractor
//  de-duplicates within one call (type + lower-cased value, first email
//  wins). Memory grows with the number of DISTINCT indicators — the result
//  itself — never with the number of emails.
//

import Foundation

@MainActor
enum IOCEngine {
    struct Progress: Codable, Sendable { var emails = 0 }

    static func extract(scope: ArchiveScope) async throws -> (entries: [IOCEntry], receipt: ScopeJobReceipt) {
        var seen = Set<String>()
        var entries: [IOCEntry] = []
        let result = try await ScopeJob.run(
            key: "ioc.extract", title: String(localized: "Extract indicators"),
            capability: .v3IOC, query: scope.query, resumable: false, initialState: Progress()
        ) { state, batch in
            let found = await Task.detached(priority: .userInitiated) { IOCExtractor.extract(from: batch) }.value
            for entry in found where seen.insert("\(entry.type.rawValue):\(entry.value.lowercased())").inserted {
                entries.append(entry)
            }
            state.emails += batch.count
        }
        return (entries, result.receipt)
    }
}
