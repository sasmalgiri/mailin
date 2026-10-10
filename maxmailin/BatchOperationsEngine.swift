@testable import ArchiveCore
//
//  BatchOperationsEngine.swift
//  maxmailin
//
//  §3-L11 (switch: `v3BatchOperations`). Tag / classify / un-tag EVERY email
//  in scope, in the database, page by page — not only the selected rows.
//  Removing a tag removes exactly that tag (the previous panel cleared every
//  tag). The loaded rows are refreshed through the review service so the
//  list shows the change at once.
//

import Foundation

@MainActor
enum BatchOperationsEngine {
    enum Operation: Sendable {
        case add(String)
        case remove(String)
    }

    struct Progress: Codable, Sendable { var done = 0 }

    static func apply(_ op: Operation, scope: ArchiveScope, loaded: [UUID]) async throws -> (count: Int, receipt: ScopeJobReceipt) {
        let store = ScopeJobEnvironment.store
        let title: String
        switch op {
        case .add(let tag): title = String(localized: "Tag “\(tag)”")
        case .remove(let tag): title = String(localized: "Remove tag “\(tag)”")
        }
        let result = try await ScopeJob.runIDs(
            key: "batch.tag", title: title, capability: .v3BatchOperations,
            query: scope.query, batchSize: 5_000, initialState: Progress()
        ) { state, page in
            let ids = page.map(\.id)
            switch op {
            case .add(let tag): try await store.userTagAdd(tag, ids: ids)
            case .remove(let tag): try await store.userTagRemove(tag, ids: ids)
            }
            state.done += ids.count
        }
        // Refresh the rows on screen (idempotent writes).
        switch op {
        case .add(let tag): ReviewStateService.shared.addTag(tag, to: loaded)
        case .remove(let tag): ReviewStateService.shared.removeTag(tag, from: loaded)
        }
        ScopeJobEnvironment.logAction(
            "Bulk Tag Applied",
            detail: "\(title) on \(result.state.done) email(s) — scope: \(result.receipt.scope)")
        return (result.state.done, result.receipt)
    }
}
