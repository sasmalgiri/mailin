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
//  Safe resume identity (Part B5):
//  Mid-file checkpoints record the ORDINAL of the last parsed message that was
//  persisted + indexed (messages [0, messagesIngested) are committed), bound
//  to: source SHA-256 + source byte size + parser type + parser version +
//  checkpoint schema version. Parsing is deterministic for a fixed file +
//  parser version, so the ordinal is stable regardless of the batch size used
//  — changing the batch size between sessions can shift batch boundaries but
//  can never skip evidence. Any identity mismatch (including legacy
//  batch-count checkpoints from schema v1) refuses to resume and restarts the
//  file from scratch — correctness over speed.
//
//  Error surfacing (Part B3):
//  Checkpoint WRITES throw — a batch is not committed until its checkpoint
//  persists, so the import must fail-stop rather than advance on a swallowed
//  write error. Loads tolerate a missing file, but a present-yet-undecodable
//  file is CORRUPTION: it is logged as a fault, moved aside for forensics,
//  and exposed via `corruptionDetected()` — never silently treated as empty.
//

import Foundation
import os

actor ImportCheckpointStore {

    static let shared = ImportCheckpointStore()

    /// Bump whenever resume semantics change (schema v1 recorded batch
    /// counts; v2 records message ordinals). Entries written under another
    /// schema are never resumed.
    static let checkpointSchemaVersion = 2

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                       category: "ImportCheckpoint")

    /// Everything that must match for a mid-file resume to be safe.
    struct ResumeIdentity: Sendable, Equatable {
        var sha256: String
        var sizeBytes: Int
        var parser: String
        var parserVersion: Int
    }

    enum CheckpointError: Error, LocalizedError {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let detail):
                return "Import checkpoint could not be saved (\(detail)). The import was stopped so no progress could be recorded incorrectly."
            }
        }
    }

    private struct Entry: Codable {
        let sha256: String
        let completedAt: Date
        let emailCount: Int
        let sourceName: String
    }

    /// In-progress checkpoint for a file that is being ingested but not yet
    /// fully complete. `messagesIngested` is the count of leading parsed
    /// messages that have been persisted + indexed; resuming skips exactly
    /// those ordinals. The identity fields guard against resuming with a
    /// different parser/version/source than the one that wrote the
    /// checkpoint. Legacy (schema v1) entries carry only `batchesIngested`
    /// and are never resumed.
    private struct InProgressEntry: Codable {
        let sha256: String
        let sourceName: String
        var lastUpdatedAt: Date
        // Legacy schema v1 field (batch-count based). Kept for decode
        // compatibility; never used to resume.
        var batchesIngested: Int?
        // Schema v2 identity + ordinal.
        var schemaVersion: Int?
        var sizeBytes: Int?
        var parser: String?
        var parserVersion: Int?
        var messagesIngested: Int?
    }

    private var entries: [String: Entry] = [:]
    private var inProgress: [String: InProgressEntry] = [:]
    private var didLoad = false
    private var corruptFileDetected = false
    private let overrideStoreURL: URL?

    private init() {
        overrideStoreURL = nil
    }

    /// Test hook: an isolated store rooted at an explicit file URL.
    init(storeURL: URL) {
        overrideStoreURL = storeURL
    }

    // MARK: - Public API

    /// True if a file with this hash has already been fully ingested.
    func isImported(sha256: String) -> Bool {
        loadIfNeeded()
        return entries[sha256] != nil
    }

    /// True when a checkpoint file existed on disk but could not be decoded.
    /// Callers must surface this (the store starts empty, so previously
    /// ingested files will be re-imported — safe, but worth telling the user).
    func corruptionDetected() -> Bool {
        loadIfNeeded()
        return corruptFileDetected
    }

    /// Record that a file has been fully ingested (persisted + indexed).
    /// Idempotent: re-recording the same hash overwrites the prior entry.
    /// Also clears any in-progress checkpoint for this file since it's done.
    /// Throws when the checkpoint cannot be persisted (Part B3).
    func record(sha256: String, sourceName: String, emailCount: Int) throws {
        loadIfNeeded()
        entries[sha256] = Entry(
            sha256: sha256,
            completedAt: Date(),
            emailCount: emailCount,
            sourceName: sourceName
        )
        inProgress.removeValue(forKey: sha256)
        try save()
    }

    /// Number of leading parsed messages already persisted + indexed for
    /// this source, or 0 when there is no checkpoint or its identity does
    /// not match (different size / parser / parser version / schema — the
    /// file must restart from scratch; never guess).
    func resumePoint(for identity: ResumeIdentity) -> Int {
        loadIfNeeded()
        guard let entry = inProgress[identity.sha256],
              entry.schemaVersion == Self.checkpointSchemaVersion,
              entry.sizeBytes == identity.sizeBytes,
              entry.parser == identity.parser,
              entry.parserVersion == identity.parserVersion,
              let messages = entry.messagesIngested, messages > 0 else {
            return 0
        }
        return messages
    }

    /// Record mid-file progress: messages [0, messagesIngested) of this
    /// source are persisted + indexed. Called after each batch's persist +
    /// index complete. Throws when the write fails — the caller must treat
    /// the batch as NOT committed and stop advancing (Part B3).
    func recordProgress(identity: ResumeIdentity, sourceName: String, messagesIngested: Int) throws {
        loadIfNeeded()
        inProgress[identity.sha256] = InProgressEntry(
            sha256: identity.sha256,
            sourceName: sourceName,
            lastUpdatedAt: Date(),
            batchesIngested: nil,
            schemaVersion: Self.checkpointSchemaVersion,
            sizeBytes: identity.sizeBytes,
            parser: identity.parser,
            parserVersion: identity.parserVersion,
            messagesIngested: messagesIngested
        )
        try save()
    }

    /// Forget every checkpoint (used by "clear all data" flows).
    func reset() throws {
        loadIfNeeded()
        entries.removeAll()
        inProgress.removeAll()
        try save()
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
        guard let url = try? storeURL() else { return }
        guard let data = try? Data(contentsOf: url) else { return } // missing file: fine
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            entries = state.entries
            inProgress = state.inProgress
        } else if let legacy = try? decoder.decode([String: Entry].self, from: data) {
            // Backwards-compat: earlier versions stored just `[String: Entry]`.
            entries = legacy
            inProgress = [:]
        } else {
            // The file exists but decodes as neither format — corruption.
            // Never treat this as silently empty: log a fault, expose the
            // flag, and move the damaged file aside so the evidence of what
            // happened is preserved instead of being clobbered by the next
            // save.
            corruptFileDetected = true
            Self.logger.fault("Import checkpoint file is corrupt and could not be decoded (\(url.lastPathComponent, privacy: .public)). Previously ingested files may be re-imported.")
            let quarantine = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: quarantine)
        }
    }

    private func save() throws {
        let url: URL
        do {
            url = try storeURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let state = PersistedState(entries: entries, inProgress: inProgress)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.fault("Import checkpoint save failed: \(error.localizedDescription, privacy: .public)")
            throw CheckpointError.writeFailed(error.localizedDescription)
        }
    }

    private func storeURL() throws -> URL {
        if let overrideStoreURL { return overrideStoreURL }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent(
            "com.ecosanskriti.mailin", isDirectory: true
        )
        return dir.appendingPathComponent("import_checkpoints.json")
    }
}
