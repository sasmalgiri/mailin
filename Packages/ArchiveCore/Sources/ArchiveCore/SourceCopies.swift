//
//  SourceCopies.swift
//  ArchiveCore
//
//  Five jobs LIFE-01: a self-contained archive.
//
//  Messages above the offset engine's full-parse ceiling are stored as byte
//  locators into the source file, so until now the archive depended on the
//  original staying where it was imported from. With the switch on, the
//  import copies each single-file source into managed storage FIRST — the
//  copy is verified byte for byte against the SHA-256 the import already
//  computed — and parses the copy, so every locator points inside the
//  archive and the original is never needed again.
//
//  With the switch off (linked mode, the previous behaviour) the archive
//  can at least say which originals are missing and relink one after
//  verifying it is the same file.
//
//  Directory sources (Maildir, EML folders, Apple Mail packages) are not
//  copied: their messages are parsed in full (no locators), so nothing in
//  them is read from the original later.
//

import CryptoKit
import Foundation
import SQLite3

/// Pushed by CapabilityWiring (`selfContainedArchive`).
public enum SourceCopyPolicy {
    nonisolated(unsafe) public static var isEnabled = false
}

enum SourceCopyError: Error, LocalizedError, Equatable {
    case digestMismatch(expected: String, actual: String)
    case notAFile(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .digestMismatch(let expected, let actual):
            return "The copy does not match the original (expected \(expected.prefix(12))…, got \(actual.prefix(12))…); the copy was discarded."
        case .notAFile(let path):
            return "\(path) is not a file that can be copied into the archive."
        case .ioError(let detail):
            return detail
        }
    }
}

enum SourceCopies {
    /// `<archive>/sources/<sha256>/<original file name>`.
    static func directory(in storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent("sources", isDirectory: true)
    }

    static func copyURL(sha256: String, filename: String, storeDirectory: URL) -> URL {
        directory(in: storeDirectory).appendingPathComponent(sha256, isDirectory: true).appendingPathComponent(filename)
    }

    /// The verified copy of this source, when one exists.
    static func existingCopy(sha256: String, filename: String, storeDirectory: URL) -> URL? {
        let url = copyURL(sha256: sha256, filename: filename, storeDirectory: storeDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy `original` into the archive, hashing while copying; the copy is
    /// kept only if its digest equals `sha256`. Writes to a temporary name
    /// and moves into place, so a crash mid-copy leaves no half file where a
    /// copy is expected. Returns the copy's URL.
    static func copyIntoArchive(original: URL, sha256: String, storeDirectory: URL,
                                chunkSize: Int = 4 * 1_048_576) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SourceCopyError.notAFile(original.path)
        }
        let destination = copyURL(sha256: sha256, filename: original.lastPathComponent, storeDirectory: storeDirectory)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".copying-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let input = FileHandle(forReadingAtPath: original.path),
              let output = FileHandle(forWritingAtPath: temporary.path) else {
            try? FileManager.default.removeItem(at: temporary)
            throw SourceCopyError.ioError("cannot open \(original.lastPathComponent) for copying")
        }
        defer { try? input.close(); try? output.close() }
        var hasher = SHA256()
        do {
            while true {
                guard let chunk = try autoreleasepool(invoking: { try input.read(upToCount: chunkSize) }), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw SourceCopyError.ioError(error.localizedDescription)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else {
            try? FileManager.default.removeItem(at: temporary)
            throw SourceCopyError.digestMismatch(expected: sha256, actual: actual)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw SourceCopyError.ioError(error.localizedDescription)
        }
        return destination
    }

    /// Bytes held by every copy, for the storage picture.
    static func totalBytes(storeDirectory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory(in: storeDirectory),
                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// SHA-256 of a file, streamed.
    static func sha256(of url: URL, chunkSize: Int = 4 * 1_048_576) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw SourceCopyError.ioError("cannot open \(url.path)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Linked mode: missing originals and relinking

struct MissingLocatorSource: Sendable, Equatable, Identifiable {
    /// SHA-256 recorded at import; empty for locators that predate digests.
    let sourceDigest: String
    let sourcePath: String
    /// Messages with a byte locator into this file (attachments and exports
    /// are served from it).
    let messages: Int
    /// Of those, the messages whose body was never decoded — the file is
    /// their only copy.
    let deferredMessages: Int
    var id: String { sourceDigest.isEmpty ? sourcePath : sourceDigest }
    var filename: String { (sourcePath as NSString).lastPathComponent }
}

enum RelinkError: Error, LocalizedError, Equatable {
    case fileMissing(String)
    case digestMismatch(expected: String, actual: String)
    case noDigestRecorded

    var errorDescription: String? {
        switch self {
        case .fileMissing(let path): return "\(path) could not be read."
        case .digestMismatch: return "That file is not the original: its contents differ from what was imported. Nothing was changed."
        case .noDigestRecorded: return "These messages were imported before source digests were recorded, so the file cannot be verified."
        }
    }
}

extension SQLiteEmailStore {
    /// Source files that locator-backed messages still depend on and that
    /// are not where they were imported from (nor copied into the archive).
    func missingLocatorSources() throws -> [MissingLocatorSource] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT COALESCE(source_digest, ''), source_path, COUNT(*),
                   SUM(CASE WHEN body_decoded = 0 THEN 1 ELSE 0 END)
            FROM message_locators
            GROUP BY source_digest, source_path ORDER BY source_path;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [MissingLocatorSource] = []
        while try stepRow(stmt, db) {
            let path = columnText(stmt, 1)
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            out.append(MissingLocatorSource(sourceDigest: columnText(stmt, 0), sourcePath: path,
                                            messages: Int(sqlite3_column_int64(stmt, 2)),
                                            deferredMessages: Int(sqlite3_column_int64(stmt, 3))))
        }
        return out
    }

    /// Point every locator of one source at `newURL` — only after the file's
    /// SHA-256 equals the digest recorded at import. Returns how many
    /// locators moved.
    func relinkLocators(sourceDigest: String, to newURL: URL) throws -> Int {
        guard !sourceDigest.isEmpty else { throw RelinkError.noDigestRecorded }
        guard FileManager.default.fileExists(atPath: newURL.path) else { throw RelinkError.fileMissing(newURL.path) }
        let actual: String
        do { actual = try SourceCopies.sha256(of: newURL) } catch { throw RelinkError.fileMissing(newURL.path) }
        guard actual == sourceDigest.lowercased() else {
            throw RelinkError.digestMismatch(expected: sourceDigest, actual: actual)
        }
        let db = try ensureDB()
        let stmt = try prepare(db, "UPDATE message_locators SET source_path = ? WHERE source_digest = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, newURL.path)
        bindText(stmt, 2, sourceDigest)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return Int(sqlite3_changes(db))
    }
}
