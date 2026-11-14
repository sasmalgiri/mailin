//
//  SearchSpecTransport.swift
//  ArchiveCore
//
//  v4.0 SEARCH-02: one serialised `SearchSpec` that travels unchanged
//  between the toolbar's Advanced Search, saved searches and recipes, plus
//  the distinction between a LIVE search (re-run against whatever the archive
//  holds now) and a FROZEN execution selection (the rows the search matched
//  at one store revision, which an import cannot change).
//
//  Text form: "mailin-search:" followed by the spec's JSON (sorted keys). The
//  JSON carries `version`; a spec written by a newer mailin is refused rather
//  than run as a different query. Dates stay "yyyy-MM-dd" plus a time-zone
//  identifier per condition, so a whole day in the zone it was chosen in
//  survives every hop.
//
//  Recipes read a field value through `spec(fromRecipeValue:)` /
//  `recipeQuery(value:base:)`: an encoded spec is decoded, ordinary words go
//  through the plain search box's translator, so both run on the same model.
//

import Foundation

enum SearchSpecTransport {
    static let prefix = "mailin-search:"

    enum DecodeError: Error, Equatable {
        /// Not a mailin search, or its JSON does not decode.
        case malformed
        /// Written by a newer version of mailin than this one understands.
        case newerVersion(Int)
    }

    /// The spec as one line of text (stable: sorted keys).
    static func encode(_ spec: SearchSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(spec), let json = String(data: data, encoding: .utf8) else {
            // Encoding plain value types cannot fail; an empty spec is the safe answer.
            return prefix + "{\"groups\":[],\"version\":\(SearchSpec.currentVersion)}"
        }
        return prefix + json
    }

    static func isEncoded(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }

    static func decode(_ text: String) throws -> SearchSpec {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw DecodeError.malformed }
        return try decodeJSON(Data(trimmed.dropFirst(prefix.count).utf8))
    }

    /// JSON as stored inside saved searches and recipes; refuses newer versions.
    static func decodeJSON(_ data: Data) throws -> SearchSpec {
        struct VersionProbe: Decodable { let version: Int? }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { throw DecodeError.malformed }
        if let version = probe.version, version > SearchSpec.currentVersion { throw DecodeError.newerVersion(version) }
        guard let spec = try? JSONDecoder().decode(SearchSpec.self, from: data) else { throw DecodeError.malformed }
        return spec
    }

    // MARK: Recipes

    /// A recipe field's value as a spec: an encoded spec, or the words a person
    /// typed (the plain search box's grammar). Nil when there is nothing to
    /// search for, or when an encoded spec cannot be read — never a different query.
    static func spec(fromRecipeValue value: String) -> SearchSpec? {
        if isEncoded(value) {
            guard let spec = try? decode(value), !spec.isEmpty, spec.isValid else { return nil }
            return spec
        }
        return PlainSearchTranslator.spec(from: value)
    }

    /// The query a recipe runs: `base` carries the scope (source, folder,
    /// trash, frozen bound), the spec rides on top exactly as the toolbar's does.
    static func recipeQuery(value: String, base: EmailQuery = .all) -> EmailQuery? {
        guard let spec = spec(fromRecipeValue: value) else { return nil }
        var q = base
        q.spec = spec
        return q
    }
}

/// SEARCH-02: the rows a search matched at one store revision. The live query
/// re-runs on whatever the archive holds; the frozen one only ever sees rows
/// that existed at `revision` (OUT-02's row bound), including the Free plan's
/// newest-N window as it was then. Codable, so a recipe or an export can keep
/// it and resume on the same rows.
struct FrozenSearchSelection: Codable, Equatable, Sendable {
    /// The query as it was asked (no bound) — what "run again" re-runs.
    let liveQuery: EmailQuery
    /// The store revision (highest row id) the selection is frozen at.
    let revision: Int64
    let frozenAt: Date

    /// The query bound to `revision`: pages, counts and streams through it
    /// never include rows inserted afterwards.
    var query: EmailQuery {
        var q = liveQuery
        q.snapshotMaxRowID = revision
        return q
    }

    init(liveQuery: EmailQuery, revision: Int64, frozenAt: Date = Date()) {
        var live = liveQuery
        live.snapshotMaxRowID = nil
        self.liveQuery = live
        self.revision = revision
        self.frozenAt = frozenAt
    }

    /// Freezes `query` at the archive's current revision. Nil when the archive
    /// is not the SQLite store (nothing to freeze to).
    static func freeze(_ query: EmailQuery, archive: ArchiveDataService) async throws -> FrozenSearchSelection? {
        guard let bound = try await archive.selectionSnapshotBound() else { return nil }
        return FrozenSearchSelection(liveQuery: query, revision: bound)
    }
}
