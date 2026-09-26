//
//  ArchiveBrowseState.swift
//  maxmailin
//
//  v2.1 backlog #6: the browse/filter state that BOTH list surfaces share —
//  the Simple list (`ArchiveListView`) and the full list
//  (`ParsedEmailListViewModel`) — in one value type with one compile step, so
//  a search string, a date bound, an attachment toggle or a sort means the
//  same query whichever list is on screen. Before this, the Simple list built
//  a bare `EmailQuery(text:…)` (operators such as `from:` were searched as
//  literal text there) while the full list compiled through
//  `ArchiveQueryCompiler`; the two disagreed on what a search string meant.
//
//  Deliberately small: it holds what both lists have, not everything the full
//  list has. Sidebar multi-selections, quick chips and review flags stay on
//  the full list's model and are layered on top through `base`.
//

import Foundation

struct ArchiveBrowseState: Equatable, Sendable {
    var searchText: String = ""
    var afterDate: Date? = nil
    var beforeDate: Date? = nil
    /// nil = no attachment constraint.
    var hasAttachments: Bool? = nil
    var includeTrashed: Bool = false
    var sort: EmailSortOrder = .dateDesc

    /// The archive-wide query: `base` carries the surface's own extra
    /// predicates; this state's fields are applied on top, then the search
    /// string is compiled (operators become fields, the rest is FTS text).
    func query(base: EmailQuery = .all) -> EmailQuery {
        var q = base
        if let afterDate { q.afterDate = afterDate }
        if let beforeDate { q.beforeDate = beforeDate }
        if let hasAttachments { q.hasAttachments = hasAttachments }
        if includeTrashed { q.includeTrashed = true }
        q.sort = sort
        return ArchiveQueryCompiler.compile(searchText.trimmingCharacters(in: .whitespacesAndNewlines), base: q)
    }

    var isDefault: Bool { self == ArchiveBrowseState() }
}
