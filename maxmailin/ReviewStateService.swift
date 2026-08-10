//
//  ReviewStateService.swift
//  maxmailin
//
//  §19/§20: durable review state (pin / read / archive / trash, user tags,
//  annotations) backed by indexed SQLite tables — replacing the archive-sized
//  in-memory Sets + `user_review_data.json` authority.
//
//  Memory contract: the service holds ONLY a visible-window cache (the IDs the
//  UI is currently showing). Sync accessors read that window; mutations update
//  the window optimistically and write through to SQLite. Errors surface via
//  `lastError` — never `try?`-swallowed.
//
//  Trash semantics (§19.1): "Delete" in the UI is Move to Trash (a soft flag).
//  Restore clears it. Permanent deletion is a distinct, explicit operation
//  that removes the row + FTS entry — never the default.
//

import Foundation
import os.log

@MainActor
final class ReviewStateService: ObservableObject {

    static let shared = ReviewStateService()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "ReviewState")

    /// Test seam: route to a disposable store instead of the shared one.
    static var testStoreOverride: SQLiteEmailStore?
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }

    // Visible-window caches — bounded by what's on screen, never the archive.
    @Published private(set) var windowStates: [UUID: SQLiteEmailStore.ReviewStateRow] = [:]
    @Published private(set) var windowTags: [UUID: Set<String>] = [:]
    @Published private(set) var windowAnnotations: [UUID: String] = [:]
    /// Distinct tag vocabulary (bounded aggregate, refreshed after mutations).
    @Published private(set) var knownTags: [String] = []
    /// The most recent persistence failure, for UI surfacing (§5.5).
    @Published private(set) var lastError: String?

    /// Monotonic token so overlapping hydrations can't clobber a newer window
    /// — and so a MUTATION invalidates any hydration snapshot taken before it
    /// (otherwise a slow hydrate could visually revert an optimistic toggle).
    private var hydrationToken = 0
    /// M4b: persists are chained so rapid toggles land in UI order — two
    /// independent Tasks have no ordering guarantee.
    private var persistChain: Task<Void, Never>?

    init() {}

    // MARK: - Window hydration

    /// Replace the visible window with review state for `ids` (one bounded
    /// read per table). Call whenever the visible page changes.
    func hydrateWindow(ids: [UUID]) async {
        hydrationToken += 1
        let token = hydrationToken
        do {
            let states = try await store.reviewStates(ids: ids)
            let tags = try await store.userTags(ids: ids)
            let notes = try await store.annotations(ids: ids)
            let vocabulary = try await store.distinctUserTags(limit: 2_000)
            guard token == hydrationToken else { return }   // a newer window won
            windowStates = states
            windowTags = tags
            windowAnnotations = notes
            knownTags = vocabulary
        } catch {
            Self.logger.error("review window hydration failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sync reads (window-backed)

    func isPinned(_ id: UUID) -> Bool { windowStates[id]?.pinned ?? false }
    func isRead(_ id: UUID) -> Bool { windowStates[id]?.isRead ?? false }
    func isArchived(_ id: UUID) -> Bool { windowStates[id]?.archived ?? false }
    func isTrashed(_ id: UUID) -> Bool { windowStates[id]?.trashed ?? false }
    func tags(for id: UUID) -> Set<String> { windowTags[id] ?? [] }
    func annotation(for id: UUID) -> String { windowAnnotations[id] ?? "" }

    // MARK: - Flag mutations (optimistic window + durable write-through)

    func setFlag(_ flag: SQLiteEmailStore.ReviewFlag, ids: [UUID], value: Bool) {
        hydrationToken += 1   // M4a: invalidate any pre-mutation snapshot
        for id in ids {
            var row = windowStates[id] ?? .init()
            switch flag {
            case .pinned: row.pinned = value
            case .isRead: row.isRead = value
            case .archived: row.archived = value
            case .trashed: row.trashed = value
            }
            windowStates[id] = row
        }
        persist("set \(flag.rawValue)=\(value)") { [store] in
            try await store.reviewSetFlag(flag, ids: ids, value: value)
        }
    }

    func togglePin(_ id: UUID) { setFlag(.pinned, ids: [id], value: !isPinned(id)) }
    func toggleRead(_ id: UUID) { setFlag(.isRead, ids: [id], value: !isRead(id)) }

    // MARK: - Trash (§19.1)

    func moveToTrash(_ ids: [UUID]) { setFlag(.trashed, ids: ids, value: true) }
    func restoreFromTrash(_ ids: [UUID]) { setFlag(.trashed, ids: ids, value: false) }

    /// Permanent, explicit destruction: store row + FTS entry. Throws — the
    /// caller must confirm and must surface failures.
    func permanentlyDelete(_ ids: [UUID]) async throws {
        // M5: FTS FIRST — a failure here leaves the canonical row for the
        // launch reconciler to re-index; store-first would leave permanent
        // ghost FTS rows the reconciler never repairs.
        for id in ids { try await FTSSearchIndex.shared.delete(id: id) }
        try await store.delete(ids: Set(ids))
        for id in ids {
            windowStates[id] = nil
            windowTags[id] = nil
            windowAnnotations[id] = nil
        }
    }

    /// Page of trashed email IDs (newest first) — the Trash view's read path.
    func trashedIDs(limit: Int, offset: Int) async throws -> [UUID] {
        try await store.reviewIDs(where: .trashed, limit: limit, offset: offset)
    }

    func trashedCount() async throws -> Int {
        try await store.reviewCount(of: .trashed)
    }

    // MARK: - Tags / annotations

    func addTag(_ tag: String, to ids: [UUID]) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        hydrationToken += 1
        for id in ids { windowTags[id, default: []].insert(cleaned) }
        if !knownTags.contains(cleaned) { knownTags = (knownTags + [cleaned]).sorted() }
        persist("tag add") { [store] in try await store.userTagAdd(cleaned, ids: ids) }
    }

    func removeTag(_ tag: String, from ids: [UUID]) {
        hydrationToken += 1
        for id in ids { windowTags[id]?.remove(tag) }
        persist("tag remove") { [store] in try await store.userTagRemove(tag, ids: ids) }
    }

    func clearAllTags(for ids: [UUID]) {
        hydrationToken += 1
        for id in ids { windowTags[id] = nil }
        persist("tag clear") { [store] in try await store.userTagsClear(ids: ids) }
    }

    func setAnnotation(_ text: String, for id: UUID) {
        hydrationToken += 1
        if text.isEmpty { windowAnnotations[id] = nil } else { windowAnnotations[id] = text }
        persist("annotation") { [store] in try await store.annotationSet(text.isEmpty ? nil : text, id: id) }
    }

    private func persist(_ what: String, _ body: @escaping @Sendable () async throws -> Void) {
        let previous = persistChain
        persistChain = Task { @MainActor in
            await previous?.value   // M4b: writes land in UI order
            do { try await body(); if lastError != nil { lastError = nil } }
            catch {
                Self.logger.fault("review-state write failed (\(what, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                lastError = "Saving review state failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - §20 one-time legacy JSON migration

    private static let migrationKey = "mailin.reviewstate.jsonMigrated.v1"

    static var legacyJSONURL: URL {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        return dir.appendingPathComponent("user_review_data.json")
    }

    struct LegacyReviewData: Codable {
        let pinnedIDs: [String]
        var readIDs: [String]? = []
        var deletedIDs: [String]? = []
        var archivedIDs: [String]? = []
        let userTags: [String: [String]]
        let annotations: [String: String]
    }

    /// Migrate `user_review_data.json` into the review tables, once. The JSON
    /// file is KEPT on disk as rollback evidence (§20); completion is marked
    /// only after count verification against the tables.
    func migrateLegacyJSONIfNeeded(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: Self.migrationKey) else { return }
        let url = Self.legacyJSONURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            defaults.set(true, forKey: Self.migrationKey)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(LegacyReviewData.self, from: data)
            let pinned = decoded.pinnedIDs.compactMap(UUID.init(uuidString:))
            let read = (decoded.readIDs ?? []).compactMap(UUID.init(uuidString:))
            // Legacy deletedIDs behaved as soft-hide → Trash, NOT destruction.
            let trashed = (decoded.deletedIDs ?? []).compactMap(UUID.init(uuidString:))
            let archived = (decoded.archivedIDs ?? []).compactMap(UUID.init(uuidString:))
            let tags = decoded.userTags.reduce(into: [UUID: Set<String>]()) {
                if let id = UUID(uuidString: $1.key) { $0[id] = Set($1.value) }
            }
            let notes = decoded.annotations.reduce(into: [UUID: String]()) {
                if let id = UUID(uuidString: $1.key) { $0[id] = $1.value }
            }
            try await store.reviewBulkImport(
                pinned: pinned, read: read, archived: archived, trashed: trashed,
                tags: tags, annotations: notes)

            // Verify before marking complete: the tables must hold at least as
            // many rows as the JSON contributed.
            let distinctFlagged = Set(pinned + read + trashed + archived).count
            // M8: the bulk import skips empty tags — counting them here would
            // make verification unpassable and re-run (re-clobber) forever.
            let expectedTags = tags.values.reduce(0) { $0 + $1.filter { !$0.isEmpty }.count }
            let totals = try await store.reviewTotals()
            guard totals.states >= distinctFlagged,
                  totals.tags >= expectedTags,
                  totals.annotations >= notes.values.filter({ !$0.isEmpty }).count else {
                Self.logger.error("review JSON migration verification failed — will retry next launch")
                return
            }
            defaults.set(true, forKey: Self.migrationKey)
            Self.logger.info("review JSON migrated: \(distinctFlagged) flagged, \(expectedTags) tags, \(notes.count) annotations")
        } catch {
            Self.logger.error("review JSON migration failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Migrating review state failed: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    static func resetMigrationForTesting(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: migrationKey)
    }
    #endif
}
