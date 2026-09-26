//
//  ImportCheckpointStore.swift
//  maxmailin
//
//  Resumable-import bookkeeping. Keyed by the source file's SHA-256, so
//  re-importing the same archive (or resuming after a crash mid-ingest) skips
//  files already fully ingested.
//
//  Two backends (v2.1 backlog #7, 2026-09-25):
//   • **store** — production. Checkpoints live in the archive's own SQLite
//     database (`import_sessions` / `import_progress`, schema v17), and the
//     mid-file ordinal is written INSIDE `insertBatch`'s transaction, so a
//     batch's rows and the ordinal that vouches for them commit together.
//     Nothing can persist a batch and forget to record it, or record it and
//     lose the rows.
//   • **json** — the pre-v17 file, kept for isolated tests and for the
//     one-time migration of an existing user's file into the store.
//
//  Safe resume identity (Part B5):
//  Mid-file checkpoints record the ORDINAL of the last parsed message that was
//  persisted, bound to: source SHA-256 + source byte size + parser type +
//  parser version + checkpoint schema version. Parsing is deterministic for a
//  fixed file + parser version, so the ordinal is stable regardless of the
//  batch size used. Any identity mismatch refuses to resume and restarts the
//  file from scratch — correctness over speed.
//
//  Error surfacing (Part B3):
//  Checkpoint WRITES throw — a batch is not committed until its checkpoint
//  persists, so the import must fail-stop rather than advance on a swallowed
//  write error. With the store backend that is now literally one COMMIT.
//  JSON loads tolerate a missing file, but a present-yet-undecodable file is
//  CORRUPTION: logged as a fault, moved aside, exposed via
//  `corruptionDetected()` — never silently treated as empty.
//

import Foundation
import os.log

actor ImportCheckpointStore {

    static let shared = ImportCheckpointStore(store: .shared)

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

    private enum Backend {
        case store(SQLiteEmailStore)
        case json(URL?)
    }

    private struct Entry: Codable {
        let sha256: String
        let completedAt: Date
        let emailCount: Int
        let sourceName: String
    }

    /// In-progress checkpoint for a file that is being ingested but not yet
    /// fully complete (JSON backend). Legacy (schema v1) entries carry only
    /// `batchesIngested` and are never resumed.
    private struct InProgressEntry: Codable {
        let sha256: String
        let sourceName: String
        var lastUpdatedAt: Date
        var batchesIngested: Int?
        var schemaVersion: Int?
        var sizeBytes: Int?
        var parser: String?
        var parserVersion: Int?
        var messagesIngested: Int?
    }

    private let backend: Backend
    private var entries: [String: Entry] = [:]
    private var inProgress: [String: InProgressEntry] = [:]
    private var didLoad = false
    private var corruptFileDetected = false
    private var didMigrateLegacyFile = false

    /// Production: checkpoints in the archive's store.
    init(store: SQLiteEmailStore) {
        backend = .store(store)
    }

    /// Test hook / legacy: an isolated JSON store at an explicit file URL.
    init(storeURL: URL) {
        backend = .json(storeURL)
    }

    /// The store this instance writes into, when it is store-backed. The
    /// coordinator uses it to decide whether a batch insert can carry the
    /// checkpoint in its own transaction.
    var backingStore: SQLiteEmailStore? {
        if case .store(let s) = backend { return s }
        return nil
    }

    // MARK: - Public API

    /// True if a file with this hash has already been fully ingested.
    func isImported(sha256: String) async -> Bool {
        switch backend {
        case .store(let store):
            await migrateLegacyFileIfNeeded(into: store)
            return (try? await store.importCheckpointIsImported(sha256: sha256)) ?? false
        case .json:
            loadIfNeeded()
            return entries[sha256] != nil
        }
    }

    /// True when a JSON checkpoint file existed on disk but could not be
    /// decoded. The store backend surfaces corruption as thrown errors at
    /// open, so it never reports true here.
    func corruptionDetected() async -> Bool {
        switch backend {
        case .store(let store):
            await migrateLegacyFileIfNeeded(into: store)
            return corruptFileDetected
        case .json:
            loadIfNeeded()
            return corruptFileDetected
        }
    }

    /// Record that a file has been fully ingested. Idempotent; clears any
    /// in-progress checkpoint for this file. Throws when it cannot persist.
    func record(sha256: String, sourceName: String, emailCount: Int) async throws {
        switch backend {
        case .store(let store):
            do { try await store.importCheckpointRecord(sha256: sha256, sourceName: sourceName, emailCount: emailCount) }
            catch { throw CheckpointError.writeFailed(error.localizedDescription) }
        case .json:
            loadIfNeeded()
            entries[sha256] = Entry(sha256: sha256, completedAt: Date(), emailCount: emailCount, sourceName: sourceName)
            inProgress.removeValue(forKey: sha256)
            try save()
        }
    }

    /// Number of leading parsed messages already persisted for this source,
    /// or 0 when there is no checkpoint or its identity does not match.
    func resumePoint(for identity: ResumeIdentity) async -> Int {
        switch backend {
        case .store(let store):
            await migrateLegacyFileIfNeeded(into: store)
            return (try? await store.importCheckpointResumePoint(
                sha256: identity.sha256, sizeBytes: identity.sizeBytes, parser: identity.parser,
                parserVersion: identity.parserVersion, schemaVersion: Self.checkpointSchemaVersion)) ?? 0
        case .json:
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
    }

    /// The checkpoint a batch insert can commit atomically, or nil when this
    /// instance does not write into `store` (then the caller records
    /// progress separately with `recordProgress`).
    func progressCheckpoint(identity: ResumeIdentity, sourceName: String, firstOrdinal: Int,
                            store: SQLiteEmailStore) -> SQLiteEmailStore.ImportProgressCheckpoint? {
        guard case .store(let mine) = backend, mine === store else { return nil }
        return SQLiteEmailStore.ImportProgressCheckpoint(
            sha256: identity.sha256, sourceName: sourceName, sizeBytes: identity.sizeBytes,
            parser: identity.parser, parserVersion: identity.parserVersion,
            schemaVersion: Self.checkpointSchemaVersion, firstOrdinal: firstOrdinal)
    }

    /// Record mid-file progress: messages [0, messagesIngested) of this
    /// source are persisted. Throws when the write fails — the caller must
    /// treat the batch as NOT committed and stop advancing (Part B3).
    func recordProgress(identity: ResumeIdentity, sourceName: String, messagesIngested: Int) async throws {
        switch backend {
        case .store(let store):
            let cp = SQLiteEmailStore.ImportProgressCheckpoint(
                sha256: identity.sha256, sourceName: sourceName, sizeBytes: identity.sizeBytes,
                parser: identity.parser, parserVersion: identity.parserVersion,
                schemaVersion: Self.checkpointSchemaVersion, firstOrdinal: 0)
            do { try await store.importCheckpointRecordProgress(cp, messagesIngested: messagesIngested) }
            catch { throw CheckpointError.writeFailed(error.localizedDescription) }
        case .json:
            loadIfNeeded()
            inProgress[identity.sha256] = InProgressEntry(
                sha256: identity.sha256, sourceName: sourceName, lastUpdatedAt: Date(),
                batchesIngested: nil, schemaVersion: Self.checkpointSchemaVersion,
                sizeBytes: identity.sizeBytes, parser: identity.parser,
                parserVersion: identity.parserVersion, messagesIngested: messagesIngested)
            try save()
        }
    }

    /// Forget every checkpoint (used by "clear all data" flows).
    func reset() async throws {
        switch backend {
        case .store(let store):
            do { try await store.importCheckpointReset() }
            catch { throw CheckpointError.writeFailed(error.localizedDescription) }
        case .json:
            loadIfNeeded()
            entries.removeAll()
            inProgress.removeAll()
            try save()
        }
    }

    /// Diagnostic: how many distinct source files have been fully ingested.
    func importedCount() async -> Int {
        switch backend {
        case .store(let store):
            await migrateLegacyFileIfNeeded(into: store)
            return (try? await store.importCheckpointSessionCount()) ?? 0
        case .json:
            loadIfNeeded()
            return entries.count
        }
    }

    // MARK: - One-time migration of the pre-v17 JSON file

    /// Reads the legacy `import_checkpoints.json` once, copies its sessions
    /// and identity-bound progress rows into the store, and renames the file
    /// so it is never read again. Legacy schema-v1 (batch-count) rows are not
    /// migrated: they were never resumable.
    private func migrateLegacyFileIfNeeded(into store: SQLiteEmailStore) async {
        guard !didMigrateLegacyFile else { return }
        didMigrateLegacyFile = true
        let url = Self.legacyJSONURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        var legacyEntries: [String: Entry] = [:]
        var legacyProgress: [String: InProgressEntry] = [:]
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            legacyEntries = state.entries
            legacyProgress = state.inProgress
        } else if let flat = try? decoder.decode([String: Entry].self, from: data) {
            legacyEntries = flat
        } else {
            corruptFileDetected = true
            Self.logger.fault("Legacy import checkpoint file is corrupt and could not be migrated (\(url.lastPathComponent, privacy: .public)).")
            let quarantine = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return
        }
        do {
            for entry in legacyEntries.values {
                try await store.importCheckpointRecord(sha256: entry.sha256, sourceName: entry.sourceName, emailCount: entry.emailCount)
            }
            for row in legacyProgress.values
            where row.schemaVersion == Self.checkpointSchemaVersion {
                guard let size = row.sizeBytes, let parser = row.parser, let version = row.parserVersion,
                      let messages = row.messagesIngested, messages > 0 else { continue }
                let cp = SQLiteEmailStore.ImportProgressCheckpoint(
                    sha256: row.sha256, sourceName: row.sourceName, sizeBytes: size, parser: parser,
                    parserVersion: version, schemaVersion: Self.checkpointSchemaVersion, firstOrdinal: 0)
                try await store.importCheckpointRecordProgress(cp, messagesIngested: messages)
            }
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("migrated-v17"))
            Self.logger.info("migrated \(legacyEntries.count) completed and \(legacyProgress.count) in-progress import checkpoints into the store")
        } catch {
            // Leave the file in place; the next launch tries again.
            didMigrateLegacyFile = false
            Self.logger.error("legacy checkpoint migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - JSON persistence (legacy / tests)

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
            entries = legacy
            inProgress = [:]
        } else {
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
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = PersistedState(entries: entries, inProgress: inProgress)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
            ArtifactProtection.applyBackgroundReadable(to: url)
        } catch {
            Self.logger.fault("Import checkpoint save failed: \(error.localizedDescription, privacy: .public)")
            throw CheckpointError.writeFailed(error.localizedDescription)
        }
    }

    private func storeURL() throws -> URL {
        if case .json(let override) = backend, let override { return override }
        return Self.legacyJSONURL()
    }

    /// Test seam: where the pre-v17 file is looked for during migration.
    nonisolated(unsafe) static var legacyJSONURLOverride: URL?

    nonisolated static func legacyJSONURL() -> URL {
        if let legacyJSONURLOverride { return legacyJSONURLOverride }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("import_checkpoints.json")
    }
}
