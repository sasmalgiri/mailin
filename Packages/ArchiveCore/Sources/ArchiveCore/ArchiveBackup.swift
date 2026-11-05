//
//  ArchiveBackup.swift
//  ArchiveCore
//
//  Five jobs LIFE-02: one backup of a consistent archive state that restores
//  on a clean device or user profile without the old machine's paths.
//
//  What a backup holds (all under one folder the user chooses):
//    emails.db                     the database — folders, memberships, user
//                                  tags, annotations, holds, review state,
//                                  import checkpoints, chunk index — written
//                                  with VACUUM INTO (consistent while the app
//                                  is running, no -wal to lose)
//    attachment-coverage.sqlite    per-attachment text states   (sidecars,
//    attachment-ocr.sqlite         OCR pass state                 if present)
//    blobs/**                      raw messages above the inline size
//    sources/**                    self-contained copies of imported files
//    receipts/<name>/**            import / export receipts (verification records)
//    mailin-backup-inventory.json  every file with its bytes and SHA-256,
//                                  the schema version, the counts, the list
//                                  of what was omitted and why, and the
//                                  linked-source inventory (originals the
//                                  archive still points at outside itself)
//
//  Omitted on purpose: the FTS5 year shards (rebuildable — Settings ▸ Health
//  ▸ Rebuild search index; the chunk index inside emails.db is included).
//
//  Restore verifies every hash BEFORE it touches the target. A clean-profile
//  restore needs an empty store directory; the in-place variant replaces the
//  database and sidecars only after the caller has snapshotted the current
//  database and closed its connection, and it never deletes blob or source
//  files that are already there.
//

import CryptoKit
import Foundation
import SQLite3

struct ArchiveBackupInventory: Codable, Sendable, Equatable {
    static let filename = "mailin-backup-inventory.json"
    static let currentVersion = 1

    struct File: Codable, Sendable, Equatable {
        /// Path relative to the backup folder, "/"-separated.
        let path: String
        let bytes: Int64
        let sha256: String
        /// database / sidecar / blob / source / receipt
        let kind: String
    }

    struct Counts: Codable, Sendable, Equatable {
        var emails = 0
        var attachments = 0
        var folders = 0
        var folderMemberships = 0
        var userTags = 0
        var annotations = 0
        var legalHolds = 0
        var sources = 0
        var locatorBacked = 0
    }

    /// An original file the archive still reads from outside itself (linked mode).
    struct LinkedSource: Codable, Sendable, Equatable {
        let path: String
        let sha256: String?
        let messages: Int
    }

    var version = ArchiveBackupInventory.currentVersion
    var createdAt: Date
    var schemaVersion: Int
    var counts: Counts
    var files: [File]
    var omitted: [String]
    var linkedSources: [LinkedSource]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

enum ArchiveBackupError: LocalizedError, Equatable {
    case destinationNotEmpty(String)
    case targetNotClean(String)
    case inventoryMissing
    case fileMissing(String)
    case hashMismatch(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationNotEmpty(let p): return "The backup folder \(p) is not empty. Choose an empty folder; nothing was written."
        case .targetNotClean(let p): return "An archive already exists at \(p). A clean-profile restore needs an empty store folder; nothing was changed."
        case .inventoryMissing: return "This folder has no mailin backup inventory, so it cannot be verified. Nothing was changed."
        case .fileMissing(let p): return "The backup is incomplete: \(p) is missing. Nothing was changed."
        case .hashMismatch(let p): return "The backup is damaged: \(p) does not match its recorded SHA-256. Nothing was changed."
        case .copyFailed(let why): return "The backup could not be written: \(why)"
        }
    }
}

enum ArchiveBackup {
    static let databaseName = "emails.db"
    static let sidecarNames = ["attachment-coverage.sqlite", "attachment-ocr.sqlite"]
    static let blobsFolder = "blobs"
    static let sourcesFolder = "sources"
    static let receiptsFolder = "receipts"

    // MARK: Create

    /// Writes a backup of `store` into `destination` (must be empty or absent).
    /// `receiptDirectories` are copied under `receipts/<name>/` when present.
    static func create(store: SQLiteEmailStore, to destination: URL,
                       receiptDirectories: [(name: String, url: URL)] = [],
                       progress: (@Sendable (String) -> Void)? = nil) async throws -> ArchiveBackupInventory {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path),
           let existing = try? fm.contentsOfDirectory(atPath: destination.path), !existing.isEmpty {
            throw ArchiveBackupError.destinationNotEmpty(destination.path)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // LIFE-04: a backup is the whole archive in one folder — owner-only
        // on macOS (0700), protected until first unlock on iOS, like the store.
        ArtifactProtection.applyBackgroundReadable(to: destination)
        var files: [ArchiveBackupInventory.File] = []

        // 1. The database, consistent.
        progress?("database")
        let dbTarget = destination.appendingPathComponent(databaseName)
        try await store.backupDatabase(to: dbTarget)
        files.append(try entry(for: dbTarget, relative: databaseName, kind: "database"))

        // 2. Sidecars, each through its own read connection.
        let storeDirectory = store.storeDirectory
        for name in sidecarNames {
            let source = storeDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            progress?(name)
            let target = destination.appendingPathComponent(name)
            try vacuumCopy(from: source, to: target)
            files.append(try entry(for: target, relative: name, kind: "sidecar"))
        }

        // 3. Blobs and self-contained source copies: immutable, content-addressed files.
        for (folder, kind) in [(blobsFolder, "blob"), (sourcesFolder, "source")] {
            let root = storeDirectory.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: root.path) else { continue }
            progress?(folder)
            files.append(contentsOf: try copyTree(from: root, to: destination.appendingPathComponent(folder, isDirectory: true),
                                                  relativePrefix: folder, kind: kind))
        }

        // 4. Receipts — the verification records.
        for receipt in receiptDirectories where fm.fileExists(atPath: receipt.url.path) {
            progress?("receipts")
            let prefix = receiptsFolder + "/" + receipt.name
            files.append(contentsOf: try copyTree(from: receipt.url, to: destination.appendingPathComponent(prefix, isDirectory: true),
                                                  relativePrefix: prefix, kind: "receipt"))
        }

        // 5. The inventory.
        let counts = try await store.backupCounts()
        let inventory = ArchiveBackupInventory(
            createdAt: Date(),
            schemaVersion: try await store.schemaVersion(),
            counts: counts,
            files: files,
            omitted: ["fts5 search shards — rebuildable from the database (Settings ▸ Health ▸ Rebuild search index); the in-database chunk index is included"],
            linkedSources: try await store.linkedSourceInventory())
        try write(inventory, to: destination)
        return inventory
    }

    // MARK: Verify

    struct Verification: Sendable, Equatable {
        var inventory: ArchiveBackupInventory
        var problems: [String]
        var isClean: Bool { problems.isEmpty }
    }

    /// Re-hashes every listed file (full, never sampled).
    static func verify(backup: URL) throws -> Verification {
        let inventory = try load(from: backup)
        var problems: [String] = []
        for file in inventory.files {
            let url = backup.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { problems.append("missing: \(file.path)"); continue }
            if try ExportInventory.sha256(of: url) != file.sha256 { problems.append("changed: \(file.path)") }
        }
        return Verification(inventory: inventory, problems: problems)
    }

    // MARK: Restore

    enum RestoreMode: Sendable, Equatable {
        /// The target store directory holds no archive (new device / profile).
        case cleanProfile
        /// Replace the database and sidecars of an existing store; add blob
        /// and source files that are missing; never delete anything. The
        /// caller has snapshotted the current database and closed its connection.
        case replaceDatabaseKeepFiles
    }

    /// Verifies the whole backup first, then places it. Returns the inventory.
    /// `receiptDirectories` maps `receipts/<name>` back to a destination; files
    /// already there are kept, not overwritten.
    @discardableResult
    static func restore(backup: URL, intoStoreDirectory target: URL, mode: RestoreMode,
                        receiptDirectories: [(name: String, url: URL)] = []) throws -> ArchiveBackupInventory {
        let fm = FileManager.default
        let verification = try verify(backup: backup)
        if let first = verification.problems.first {
            if first.hasPrefix("missing") { throw ArchiveBackupError.fileMissing(String(first.dropFirst("missing: ".count))) }
            throw ArchiveBackupError.hashMismatch(String(first.dropFirst("changed: ".count)))
        }
        let dbTarget = target.appendingPathComponent(databaseName)
        if mode == .cleanProfile, fm.fileExists(atPath: dbTarget.path) {
            throw ArchiveBackupError.targetNotClean(target.path)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        // Database and sidecars: staged beside the target, then swapped in.
        for file in verification.inventory.files where file.kind == "database" || file.kind == "sidecar" {
            let source = backup.appendingPathComponent(file.path)
            let destination = target.appendingPathComponent(file.path)
            let staged = target.appendingPathComponent(file.path + ".restore-staging")
            try? fm.removeItem(at: staged)
            do {
                try fm.copyItem(at: source, to: staged)
                for suffix in ["-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: destination.path + suffix)) }
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: destination)
                }
            } catch {
                try? fm.removeItem(at: staged)
                throw ArchiveBackupError.copyFailed(error.localizedDescription)
            }
        }
        // Blobs and sources: add what is missing; existing files are left alone.
        for file in verification.inventory.files where file.kind == "blob" || file.kind == "source" {
            let destination = target.appendingPathComponent(file.path)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.copyItem(at: backup.appendingPathComponent(file.path), to: destination) }
            catch { throw ArchiveBackupError.copyFailed(error.localizedDescription) }
        }
        // Receipts back to their homes, never overwriting.
        for receipt in receiptDirectories {
            let prefix = receiptsFolder + "/" + receipt.name + "/"
            for file in verification.inventory.files where file.path.hasPrefix(prefix) {
                let destination = receipt.url.appendingPathComponent(String(file.path.dropFirst(prefix.count)))
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: backup.appendingPathComponent(file.path), to: destination)
            }
        }
        return verification.inventory
    }

    // MARK: Helpers

    static func load(from backup: URL) throws -> ArchiveBackupInventory {
        let url = backup.appendingPathComponent(ArchiveBackupInventory.filename)
        guard let data = try? Data(contentsOf: url) else { throw ArchiveBackupError.inventoryMissing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArchiveBackupInventory.self, from: data)
    }

    private static func write(_ inventory: ArchiveBackupInventory, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(inventory).write(to: destination.appendingPathComponent(ArchiveBackupInventory.filename), options: .atomic)
    }

    private static func entry(for url: URL, relative: String, kind: String) throws -> ArchiveBackupInventory.File {
        ArtifactProtection.applyBackgroundReadable(to: url)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return ArchiveBackupInventory.File(path: relative, bytes: bytes, sha256: try ExportInventory.sha256(of: url), kind: kind)
    }

    /// Copies every regular file under `root` (hidden files skipped), hashing each.
    private static func copyTree(from root: URL, to destination: URL, relativePrefix: String, kind: String) throws -> [ArchiveBackupInventory.File] {
        let fm = FileManager.default
        var out: [ArchiveBackupInventory.File] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return out }
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.copyItem(at: url, to: target) } catch { throw ArchiveBackupError.copyFailed(error.localizedDescription) }
            out.append(try entry(for: target, relative: relativePrefix + "/" + relative, kind: kind))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A consistent copy of any SQLite file through its own read connection.
    static func vacuumCopy(from source: URL, to target: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw ArchiveBackupError.copyFailed("\(source.lastPathComponent) could not be opened")
        }
        defer { sqlite3_close(handle) }
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(handle, "VACUUM INTO '\(escaped)';", nil, nil, nil) != SQLITE_OK {
            try? FileManager.default.removeItem(at: target)
            throw ArchiveBackupError.copyFailed("\(source.lastPathComponent): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }
}

extension SQLiteEmailStore {
    /// A consistent copy of the live database at `url` (VACUUM INTO).
    func backupDatabase(to url: URL) throws {
        let handle = try ensureDB()
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        do { try exec(handle, "VACUUM INTO '\(escaped)';") }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw ArchiveBackupError.copyFailed(error.localizedDescription)
        }
    }

    func backupCounts() throws -> ArchiveBackupInventory.Counts {
        let db = try ensureDB()
        var counts = ArchiveBackupInventory.Counts()
        counts.emails = try scalarInt(db, "SELECT COUNT(*) FROM emails;")
        counts.attachments = try scalarInt(db, "SELECT COUNT(*) FROM attachments;")
        counts.folders = try scalarInt(db, "SELECT COUNT(*) FROM folders;")
        counts.folderMemberships = try scalarInt(db, "SELECT COUNT(*) FROM email_folders;")
        counts.userTags = try scalarInt(db, "SELECT COUNT(*) FROM email_user_tags;")
        counts.annotations = try scalarInt(db, "SELECT COUNT(*) FROM email_annotations;")
        counts.legalHolds = try scalarInt(db, "SELECT COUNT(*) FROM legal_holds;")
        counts.sources = try scalarInt(db, "SELECT COUNT(*) FROM sources;")
        counts.locatorBacked = try scalarInt(db, "SELECT COUNT(*) FROM message_locators;")
        return counts
    }

    /// Originals the archive still reads from outside its own folder, with how many messages depend on each.
    func linkedSourceInventory() throws -> [ArchiveBackupInventory.LinkedSource] {
        let db = try ensureDB()
        let inside = storeDirectory.appendingPathComponent(ArchiveBackup.sourcesFolder, isDirectory: true).standardizedFileURL.path
        guard let stmt = try prepare(db, "SELECT source_path, source_digest, COUNT(*) FROM message_locators GROUP BY source_path, source_digest ORDER BY source_path;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [ArchiveBackupInventory.LinkedSource] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = columnText(stmt, 0)
            guard !URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(inside) else { continue }
            let digest = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : columnText(stmt, 1)
            out.append(.init(path: path, sha256: digest, messages: Int(sqlite3_column_int64(stmt, 2))))
        }
        return out
    }
}
