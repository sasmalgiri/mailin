//
//  TagOverridePersistence.swift
//  maxmailin
//
//  UserDefaults-backed storage for per-email tag corrections: manual tags
//  the user added and AI tags the user marked wrong. String-typed so the
//  codec is testable independent of the list view's private tag enum.
//

import Foundation

enum TagOverridePersistence {
    static let manualKey = "manualEmailTagOverrides"
    static let suppressedKey = "suppressedAIEmailTags"

    /// Corrections are per-email UI state, not archive data — cap the map so
    /// a decade of clicks can't bloat defaults. Oldest-insertion loss at the
    /// cap is acceptable for a correction layer.
    static let maxEntries = 5_000

    static func load(key: String, defaults: UserDefaults = .standard) -> [UUID: Set<String>] {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        var out: [UUID: Set<String>] = [:]
        for (k, v) in raw {
            guard let id = UUID(uuidString: k), !v.isEmpty else { continue }
            out[id] = Set(v)
        }
        return out
    }

    static func save(_ dict: [UUID: Set<String>], key: String, defaults: UserDefaults = .standard) {
        var trimmed = dict.filter { !$0.value.isEmpty }
        if trimmed.count > maxEntries {
            trimmed = Dictionary(uniqueKeysWithValues: trimmed.prefix(maxEntries).map { ($0.key, $0.value) })
        }
        let raw = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key.uuidString, $0.value.sorted()) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: key)
        }
    }
}
