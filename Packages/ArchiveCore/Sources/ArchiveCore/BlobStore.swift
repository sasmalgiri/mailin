//
//  BlobStore.swift
//  mailin
//
//  S3a of SIZE_LIMITS_DESIGN.md — content-addressed external storage for
//  message bodies too large to live in a SQLite value.
//
//  Why this exists: SQLite's default maximum string/BLOB length is 1 GB, and
//  that is also the maximum ROW size, because "during part of SQLite's INSERT
//  and SELECT processing, the complete content of each row in the database is
//  encoded as a single BLOB" (sqlite.org/limits.html). SQLite advises against
//  raising the limit. So a message above ~1 GB cannot be stored in
//  `email_bodies.raw` at all, whatever the parser does.
//
//  Design notes:
//   • Content-addressed by SHA-256, so identical bodies are stored once and a
//     stored blob can always be verified against its own name.
//   • Two-level directory fan-out (`ab/abcdef…`) so no directory holds a
//     million entries.
//   • Writes are temp → fsync → atomic rename. The caller commits the database
//     row AFTER the blob is durable, so a crash leaves a collectable orphan
//     rather than a row pointing at nothing. That asymmetry is deliberate:
//     an orphan wastes space, a dangling reference loses evidence.
//   • Streaming write from a file URL never materialises the whole body, which
//     is the point for a multi-gigabyte message.
//   • Range reads make attachment extraction O(part) once part locators exist
//     (S5), instead of re-parsing the whole message.
//

import Foundation
import CryptoKit

/// A durable pointer to an external body blob.
struct BlobReference: Sendable, Equatable, Codable {
    /// Lowercase hex SHA-256 of the content — also its filename.
    var digest: String
    var length: Int64
}

enum BlobStoreError: LocalizedError, Equatable {
    case notFound(String)
    case digestMismatch(expected: String, actual: String)
    case rangeOutOfBounds(offset: Int64, length: Int64, blobLength: Int64)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let digest):
            return "The stored message body \(digest.prefix(12))… is missing from the archive."
        case .digestMismatch(let expected, let actual):
            return "A stored message body failed verification: expected \(expected.prefix(12))…, found \(actual.prefix(12))…. The archive may be damaged."
        case .rangeOutOfBounds(let offset, let length, let blobLength):
            return "Requested bytes \(offset)–\(offset + length) of a \(blobLength)-byte body."
        case .writeFailed(let reason):
            return "Could not store a message body: \(reason)"
        }
    }
}

struct BlobStore: Sendable {
    let root: URL

    /// Bodies at or below this size stay inline in the database, where a
    /// single read is cheaper than a file open. Above it they go external.
    static let inlineThresholdBytes = 8 * 1_048_576   // 8 MiB

    init(root: URL) { self.root = root }

    /// `<root>/blobs` beside the SQLite store.
    static func production(storeDirectory: URL) -> BlobStore {
        BlobStore(root: storeDirectory.appendingPathComponent("blobs", isDirectory: true))
    }

    // MARK: - Paths

    func url(for digest: String) -> URL {
        // Fan out on the first two hex characters.
        let prefix = String(digest.prefix(2))
        return root
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(digest, isDirectory: false)
    }

    func exists(_ reference: BlobReference) -> Bool {
        FileManager.default.fileExists(atPath: url(for: reference.digest).path)
    }

    // MARK: - Write

    /// Stores `data`, returning its reference. Idempotent: storing identical
    /// content twice keeps one copy.
    @discardableResult
    func write(_ data: Data) throws -> BlobReference {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = BlobReference(digest: digest, length: Int64(data.count))
        let destination = url(for: digest)
        if FileManager.default.fileExists(atPath: destination.path) { return reference }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        ArtifactProtection.applyBackgroundReadable(to: destination.deletingLastPathComponent())

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            try fsync(url: temp)
            // Atomic publish: a reader never sees a partial blob under its
            // final name.
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw BlobStoreError.writeFailed(error.localizedDescription)
        }
        return reference
    }

    /// Stores the contents of `fileURL` without ever holding it all in memory —
    /// the case a multi-gigabyte message needs. Hashes and copies in one pass.
    @discardableResult
    func write(contentsOf fileURL: URL, chunkSize: Int = 4 * 1_048_576) throws -> BlobReference {
        guard let input = try? FileHandle(forReadingFrom: fileURL) else {
            throw BlobStoreError.writeFailed("cannot open \(fileURL.lastPathComponent)")
        }
        defer { try? input.close() }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".tmp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: staging) else {
            throw BlobStoreError.writeFailed("cannot create staging file")
        }

        var hasher = SHA256()
        var total: Int64 = 0
        do {
            while true {
                guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                total += Int64(chunk.count)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: staging)
            throw BlobStoreError.writeFailed(error.localizedDescription)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let destination = url(for: digest)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Already stored — drop the duplicate copy.
            try? FileManager.default.removeItem(at: staging)
            return BlobReference(digest: digest, length: total)
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw BlobStoreError.writeFailed(error.localizedDescription)
        }
        return BlobReference(digest: digest, length: total)
    }

    // MARK: - Read

    /// Whole blob. Verifies the content against its own digest, because a
    /// content-addressed store can and therefore should.
    func read(_ reference: BlobReference, verify: Bool = true) throws -> Data {
        let location = url(for: reference.digest)
        guard let data = try? Data(contentsOf: location, options: .mappedIfSafe) else {
            throw BlobStoreError.notFound(reference.digest)
        }
        if verify {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == reference.digest else {
                throw BlobStoreError.digestMismatch(expected: reference.digest, actual: actual)
            }
        }
        return data
    }

    /// A byte range, without reading the rest. This is what makes attachment
    /// extraction O(part) once part locators exist (S5).
    func read(_ reference: BlobReference, offset: Int64, length: Int64) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= reference.length else {
            throw BlobStoreError.rangeOutOfBounds(
                offset: offset, length: length, blobLength: reference.length)
        }
        guard let handle = try? FileHandle(forReadingFrom: url(for: reference.digest)) else {
            throw BlobStoreError.notFound(reference.digest)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return (try handle.read(upToCount: Int(length))) ?? Data()
    }

    // MARK: - Housekeeping

    /// Every digest currently stored.
    func storedDigests() -> Set<String> {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var digests: Set<String> = []
        for case let file as URL in walker where file.hasDirectoryPath == false {
            let name = file.lastPathComponent
            // 64 hex characters, so staging files and stray items are ignored.
            if name.count == 64, name.allSatisfy(\.isHexDigit) { digests.insert(name) }
        }
        return digests
    }

    /// Deletes blobs no row references any more. Because writes publish the
    /// blob before the row commits, an interrupted import leaves orphans —
    /// this is how they are reclaimed. Never deletes anything in `referenced`.
    @discardableResult
    func collectOrphans(referenced: Set<String>) -> (deleted: Int, bytesReclaimed: Int64) {
        var deleted = 0
        var bytes: Int64 = 0
        for digest in storedDigests() where !referenced.contains(digest) {
            let location = url(for: digest)
            let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at: location)) != nil {
                deleted += 1
                bytes += Int64(size)
            }
        }
        return (deleted, bytes)
    }

    /// Total bytes held, for the storage planner and diagnostics.
    func totalBytes() -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Private

    private func fsync(url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
