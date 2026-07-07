//
//  ImportCheckpointStore.swift
//  maxmailin
//
//  Resumable-import bookkeeping. Keyed by the source file's SHA-256, so
//  re-importing the same archive (or resuming after a crash mid-ingest) skips
//  files already fully ingested. Strictly local JSON in Application Support.
//
//  Why per-file granularity:
//  At 1 TB scale a crash at 800 GB would otherwise re-process 800 GB. Recording
//  one checkpoint per fully-imported source file caps wasted re-work at the
//  size of a single source file.
//

import Foundation

actor ImportCheckpointStore {

    static let shared = ImportCheckpointStore()

    private struct Entry: Codable {
        let sha256: String
        let completedAt: Date
        let emailCount: Int
        let sourceName: String
    }

    /// In-progress checkpoint for a file that is being ingested but not yet
    /// fully complete. Tracks the number of batches that have been
    /// successfully persisted + indexed so a crashed import can resume
    /// without re-doing already-ingested batches. Cap re-work after a
    /// crash mid-file at one batch (200 emails) instead of one file
    /// (potentially 200 GB).
    private struct InProgressEntry: Codable {
        let sha256: String
        let sourceName: String
        var batchesIngested: Int
        var lastUpdatedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inProgress: [String: InProgressEntry] = [:]
    private var didLoad = false

    private init() {}

    // MARK: - Public API

    /// True if a file with this hash has already been fully ingested.
    func isImported(sha256: String) -> Bool {
        loadIfNeeded()
        return entries[sha256] != nil
    }

    /// Record that a file has been fully ingested (persisted + indexed).
    /// Idempotent: re-recording the same hash overwrites the prior entry.
    /// Also clears any in-progress checkpoint for this file since it's done.
    func record(sha256: String, sourceName: String, emailCount: Int) {
        loadIfNeeded()
        entries[sha256] = Entry(
            sha256: sha256,
            completedAt: Date(),
            emailCount: emailCount,
            sourceName: sourceName
        )
        inProgress.removeValue(forKey: sha256)
        save()
    }

    /// Number of batches already persisted + indexed for this file's
    /// in-progress import. Returns 0 if there's no in-progress record.
    /// Callers should skip the first `batchesIngested` batches when
    /// resuming a parse.
    func batchesIngested(sha256: String) -> Int {
        loadIfNeeded()
        return inProgress[sha256]?.batchesIngested ?? 0
    }

    /// Record progress for a file that is mid-ingest. Called after each
    /// batch's persist + index both succeed. Idempotent and cheap (one
    /// JSON write per batch — well-amortized at 200 emails per batch).
    func recordBatch(sha256: String, sourceName: String, batchesIngested: Int) {
        loadIfNeeded()
        inProgress[sha256] = InProgressEntry(
            sha256: sha256,
            sourceName: sourceName,
            batchesIngested: batchesIngested,
            lastUpdatedAt: Date()
        )
        save()
    }

    /// Forget every checkpoint (used by "clear all data" flows).
    func reset() {
        entries.removeAll()
        inProgress.removeAll()
        save()
    }

    /// Diagnostic: how many distinct source files have been fully ingested.
    func importedCount() -> Int {
        loadIfNeeded()
        return entries.count
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var entries: [String: Entry]
        var inProgress: [String: InProgressEntry]
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let url = try? storeURL(),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            entries = state.entries
            inProgress = state.inProgress
        } else if let legacy = try? decoder.decode([String: Entry].self, from: data) {
            // Backwards-compat: earlier versions stored just `[String: Entry]`.
            entries = legacy
            inProgress = [:]
        }
    }

    private func save() {
        guard let url = try? storeURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let state = PersistedState(entries: entries, inProgress: inProgress)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func storeURL() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent(
            "com.ecosanskriti.mailin", isDirectory: true
        )
        return dir.appendingPathComponent("import_checkpoints.json")
    }
}
