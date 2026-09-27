@testable import ArchiveCore
//
//  OverflowSegmentStoreTests.swift
//  maxmailinTests
//
//  Phase H-1: pack → seal → upload → evict local → fetch → verify → read,
//  against a local-folder transport standing in for the ubiquity container.
//

import XCTest
@testable import maxmailin

final class OverflowSegmentStoreTests: XCTestCase {

    private func roots() throws -> (cache: URL, remote: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overflow-\(UUID().uuidString)", isDirectory: true)
        let cache = base.appendingPathComponent("cache", isDirectory: true)
        let remote = base.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return (cache, remote, base)
    }

    func testBlobsRoundTripThroughSegmentsAndSurviveLocalEviction() async throws {
        let r = try roots(); defer { try? FileManager.default.removeItem(at: r.base) }
        let store = try OverflowSegmentStore(cacheDirectory: r.cache, transport: LocalFolderTransport(root: r.remote),
                                             segmentBytes: 64 * 1024, cacheLimitBytes: 10 * 1_048_576)
        var digests: [String: Data] = [:]
        for i in 0..<40 {
            let blob = Data(repeating: UInt8(i), count: 5_000 + i * 100)
            digests[try await store.add(blob: blob)] = blob
        }
        try await store.seal()
        let manifest = await store.manifest
        XCTAssertEqual(manifest.entries.count, 40)
        XCTAssertGreaterThan(manifest.segments.count, 1, "64 KiB segments must have split 40 × ~7 KB")
        for size in manifest.segments.values { XCTAssertLessThanOrEqual(size, 64 * 1024) }

        // Every segment is remote; drop the local copies.
        for digest in manifest.segments.keys {
            let remote = try await LocalFolderTransport(root: r.remote).exists(digest: digest)
            XCTAssertTrue(remote)
            try await store.evictLocal(segmentDigest: digest)
        }
        let cached = await store.localCacheBytes()
        XCTAssertEqual(cached, 0)

        // Reads fetch, verify and return the exact bytes.
        for (digest, blob) in digests {
            let back = try await store.read(blobDigest: digest)
            XCTAssertEqual(back, blob)
        }
    }

    func testContentAddressingDeduplicates() async throws {
        let r = try roots(); defer { try? FileManager.default.removeItem(at: r.base) }
        let store = try OverflowSegmentStore(cacheDirectory: r.cache, transport: LocalFolderTransport(root: r.remote))
        let blob = Data("same bytes twice".utf8)
        let a = try await store.add(blob: blob)
        let b = try await store.add(blob: blob)
        XCTAssertEqual(a, b)
        try await store.seal()
        let count = await store.manifest.entries.count
        XCTAssertEqual(count, 1)
    }

    func testTamperedRemoteSegmentIsRefused() async throws {
        let r = try roots(); defer { try? FileManager.default.removeItem(at: r.base) }
        let transport = LocalFolderTransport(root: r.remote)
        let store = try OverflowSegmentStore(cacheDirectory: r.cache, transport: transport)
        let digest = try await store.add(blob: Data("evidence".utf8))
        try await store.seal()
        let manifest = await store.manifest
        let segment = try XCTUnwrap(manifest.entries[digest]?.segmentDigest)
        try await store.evictLocal(segmentDigest: segment)
        // Corrupt the remote copy.
        let remoteURL = r.remote.appendingPathComponent(segment + ".segment")
        try Data("tampered!".utf8).write(to: remoteURL)
        do {
            _ = try await store.read(blobDigest: digest)
            XCTFail("a segment that fails verification must never be read")
        } catch OverflowError.hashMismatch {
            // expected
        }
    }

    func testManifestPersistsAcrossReopen() async throws {
        let r = try roots(); defer { try? FileManager.default.removeItem(at: r.base) }
        let transport = LocalFolderTransport(root: r.remote)
        let digest: String
        do {
            let store = try OverflowSegmentStore(cacheDirectory: r.cache, transport: transport)
            digest = try await store.add(blob: Data("persist me".utf8))
            try await store.seal()
        }
        let reopened = try OverflowSegmentStore(cacheDirectory: r.cache, transport: transport)
        let back = try await reopened.read(blobDigest: digest)
        XCTAssertEqual(back, Data("persist me".utf8))
    }
}
