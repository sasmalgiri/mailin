//
//  SelectionSnapshot.swift
//  ArchiveCore
//
//  Five jobs OUT-02: an export of a filtered view must not drift because a
//  background import adds mail while it runs. A query scope is frozen when
//  the run starts by binding it to the store's current row bound: rows
//  inserted afterwards have higher rowids and are outside the selection for
//  pages, counts, fingerprints and streams alike. Mail removed during the run
//  simply stops appearing, and the receipt's reconciliation (selected vs
//  written) says so. The bound travels in the request, so a resume continues
//  the same frozen selection.
//
//  Stated edge: SQLite may reuse the highest rowid if the newest row is
//  permanently deleted and another inserted during the run; trash is a soft
//  delete and does not do this.
//

import Foundation

extension SQLiteEmailStore {
    /// The highest row that exists right now; the bound a fresh export freezes to.
    func selectionSnapshotBound() throws -> Int64 {
        Int64(try scalarInt(try ensureDB(), "SELECT COALESCE(MAX(rowid), 0) FROM emails;"))
    }
}

extension ArchiveDataService {
    /// Nil when the repository is not the SQLite store (nothing to freeze to).
    func selectionSnapshotBound() async throws -> Int64? {
        guard let sqlite = sqliteStore else { return nil }
        return try await sqlite.selectionSnapshotBound()
    }
}

extension ArchiveSelectionScope {
    /// The same scope frozen to `bound`. Explicit selections are already a
    /// fixed set; an already-frozen query keeps its original bound.
    func snapshotted(bound: Int64?) -> ArchiveSelectionScope {
        guard let bound, case .query(var query, let exclusions) = self, query.snapshotMaxRowID == nil else { return self }
        query.snapshotMaxRowID = bound
        return .query(query, exclusions: exclusions)
    }

    /// True when the selection cannot change under the run.
    var isFrozen: Bool {
        switch self {
        case .none, .explicit: return true
        case .query(let query, _): return query.snapshotMaxRowID != nil
        }
    }
}
