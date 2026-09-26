//
//  OverflowSegmentStore.swift
//  maxmailin
//
//  Phase H-1: the iCloud Overflow prototype's local half — the part that can
//  be built and verified before the container identifier exists.
//
//  Model: the hot database, WAL and FTS never leave the local volume. What
//  overflows is the blob tier: immutable, content-addressed SEGMENTS (a run
//  of blobs packed into one file of at most `segmentBytes`, named by its
//  SHA-256) plus a manifest that maps each blob digest to (segment, offset,
//  length). A transport moves segments to and from a remote; fetches are
//  hash-verified before use; a bounded local cache keeps recently used
//  segments. `LocalFolderTransport` stands in for the ubiquity container so
//  the whole cycle — pack, upload, evict, fetch, verify, read a blob back —
//  runs in tests today. The iCloud transport (H-2) is the only piece that
//  waits on the owner.
//

import Foundation
import CryptoKit

// MARK: - Model

struct OverflowSegmentEntry: Codable, Equatable, Sendable {
    let blobDigest: String
    let segmentDigest: String
    let offset: Int64
    let length: Int64
}

struct OverflowManifest: Codable, Equatable, Sendable {
    var version: Int = 1
    var segmentBytes: Int64
    var entries: [String: OverflowSegmentEntry] = [:]     // blob digest → location
    var segments: [String: Int64] = [:]                    // segment digest → size
    var updatedAt: Date = Date()
}

enum OverflowError: LocalizedError {
    case blobMissing(String)
    case segmentMissing(String)
    case hashMismatch(expected: String, actual: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .blobMissing(let d): return "The overflow manifest has no entry for blob \(d.prefix(12))…"
        case .segmentMissing(let d): return "Segment \(d.prefix(12))… is neither cached locally nor available from the remote."
        case .hashMismatch(let e, let a): return "A fetched segment did not verify (expected \(e.prefix(12))…, got \(a.prefix(12))…). It was discarded."
        case .transport(let m): return "Overflow transport error: \(m)"
        }
    }
}

/// Where segments live remotely. One conformer per tier; `LocalFolderTransport`
/// is the test double and the "external folder" tier.
protocol OverflowTransport: Sendable {
    func upload(segment: URL, digest: String) async throws
    func download(digest: String, to destination: URL) async throws
    func exists(digest: String) async throws -> Bool
    func remove(digest: String) async throws
}

struct LocalFolderTransport: OverflowTransport {
    let root: URL
    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func url(_ digest: String) -> URL { root.appendingPathComponent(digest + ".segment") }
    func upload(segment: URL, digest: String) async throws {
        let target = url(digest)
        if FileManager.default.fileExists(atPath: target.path) { return }   // immutable: same digest, same bytes
        try FileManager.default.copyItem(at: segment, to: target)
    }
    func download(digest: String, to destination: URL) async throws {
        let source = url(digest)
        guard FileManager.default.fileExists(atPath: source.path) else { throw OverflowError.segmentMissing(digest) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func exists(digest: String) async throws -> Bool { FileManager.default.fileExists(atPath: url(digest).path) }
    func remove(digest: String) async throws { try? FileManager.default.removeItem(at: url(digest)) }
}

// MARK: - Store

actor OverflowSegmentStore {
    let cacheDirectory: URL
    let manifestURL: URL
    let segmentBytes: Int64
    /// Bounded local cache of fetched segments, by total bytes.
    let cacheLimitBytes: Int64
    private let transport: any OverflowTransport
    private(set) var manifest: OverflowManifest

    // Segment under construction.
    private var openSegmentURL: URL?
    private var openSegmentHandle: FileHandle?
    private var openSegmentEntries: [(digest: String, offset: Int64, length: Int64)] = []
    private var openSegmentLength: Int64 = 0

    init(cacheDirectory: URL, transport: any OverflowTransport,
         segmentBytes: Int64 = 64 * 1_048_576, cacheLimitBytes: Int64 = 512 * 1_048_576) throws {
        self.cacheDirectory = cacheDirectory
        self.manifestURL = cacheDirectory.appendingPathComponent("overflow-manifest.json")
        self.segmentBytes = segmentBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.transport = transport
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder.overflow.decode(OverflowManifest.self, from: data) {
            manifest = decoded
        } else {
            manifest = OverflowManifest(segmentBytes: segmentBytes)
        }
    }

    // MARK: Pack

    /// Append a blob to the open segment; seals and uploads when full.
    func add(blob data: Data) async throws -> String {
        let digest = Self.hex(SHA256.hash(data: data))
        if manifest.entries[digest] != nil { return digest }   // content-addressed: already stored
        if openSegmentHandle == nil || openSegmentLength + Int64(data.count) > segmentBytes, openSegmentHandle != nil {
            try await seal()
        }
        if openSegmentHandle == nil { try openSegment() }
        guard let handle = openSegmentHandle else { throw OverflowError.transport("no open segment") }
        let offset = openSegmentLength
        try handle.write(contentsOf: data)
        openSegmentLength += Int64(data.count)
        openSegmentEntries.append((digest, offset, Int64(data.count)))
        return digest
    }

    /// Seal the open segment: name it by its hash, record its entries,
    /// upload it, keep it in the local cache.
    func seal() async throws {
        guard let handle = openSegmentHandle, let tempURL = openSegmentURL else { return }
        try handle.close()
        openSegmentHandle = nil
        let segmentDigest = try Self.hex(Self.sha256(ofFile: tempURL))
        let finalURL = cacheDirectory.appendingPathComponent(segmentDigest + ".segment")
        if FileManager.default.fileExists(atPath: finalURL.path) { try FileManager.default.removeItem(at: finalURL) }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        for entry in openSegmentEntries {
            manifest.entries[entry.digest] = OverflowSegmentEntry(blobDigest: entry.digest, segmentDigest: segmentDigest,
                                                                  offset: entry.offset, length: entry.length)
        }
        manifest.segments[segmentDigest] = openSegmentLength
        openSegmentEntries = []
        openSegmentLength = 0
        openSegmentURL = nil
        try await transport.upload(segment: finalURL, digest: segmentDigest)
        try saveManifest()
        try trimCache()
    }

    private func openSegment() throws {
        let url = cacheDirectory.appendingPathComponent("open-\(UUID().uuidString).segment")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        openSegmentHandle = try FileHandle(forWritingTo: url)
        openSegmentURL = url
        openSegmentLength = 0
        openSegmentEntries = []
    }

    // MARK: Read

    /// Read one blob back: from the local cache, or fetched from the remote
    /// and verified against the segment's digest before a byte is used.
    func read(blobDigest: String) async throws -> Data {
        guard let entry = manifest.entries[blobDigest] else { throw OverflowError.blobMissing(blobDigest) }
        let segmentURL = try await ensureSegmentLocal(entry.segmentDigest)
        let handle = try FileHandle(forReadingFrom: segmentURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        let data = try handle.read(upToCount: Int(entry.length)) ?? Data()
        let actual = Self.hex(SHA256.hash(data: data))
        guard actual == blobDigest else { throw OverflowError.hashMismatch(expected: blobDigest, actual: actual) }
        touch(segmentURL)
        return data
    }

    private func ensureSegmentLocal(_ digest: String) async throws -> URL {
        let local = cacheDirectory.appendingPathComponent(digest + ".segment")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let temp = cacheDirectory.appendingPathComponent("fetch-\(UUID().uuidString).segment")
        try await transport.download(digest: digest, to: temp)
        let actual = try Self.hex(Self.sha256(ofFile: temp))
        guard actual == digest else {
            try? FileManager.default.removeItem(at: temp)
            throw OverflowError.hashMismatch(expected: digest, actual: actual)
        }
        try FileManager.default.moveItem(at: temp, to: local)
        try trimCache()
        return local
    }

    // MARK: Cache

    /// Drop the local copy of sealed segments (they remain remote). Used to
    /// simulate "evicted to the cloud" and by the bounded-cache trim.
    func evictLocal(segmentDigest: String) throws {
        let local = cacheDirectory.appendingPathComponent(segmentDigest + ".segment")
        if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
    }

    func localCacheBytes() -> Int64 {
        cachedSegments().reduce(0) { $0 + $1.size }
    }

    private func cachedSegments() -> [(url: URL, size: Int64, accessed: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey])) ?? []
        return urls.filter { $0.pathExtension == "segment" && !$0.lastPathComponent.hasPrefix("open-") }.map { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            return (url, Int64(v?.fileSize ?? 0), v?.contentAccessDate ?? .distantPast)
        }
    }

    /// Least-recently-used eviction down to the limit; only segments that
    /// the transport confirms remote are dropped.
    private func trimCache() throws {
        var total = localCacheBytes()
        guard total > cacheLimitBytes else { return }
        for segment in cachedSegments().sorted(by: { $0.accessed < $1.accessed }) {
            let digest = segment.url.deletingPathExtension().lastPathComponent
            guard manifest.segments[digest] != nil else { continue }
            try? FileManager.default.removeItem(at: segment.url)
            total -= segment.size
            if total <= cacheLimitBytes { break }
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func saveManifest() throws {
        manifest.updatedAt = Date()
        try JSONEncoder.overflow.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    // MARK: Hashing

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFile url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize()
    }
}

private extension JSONEncoder {
    static var overflow: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var overflow: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
