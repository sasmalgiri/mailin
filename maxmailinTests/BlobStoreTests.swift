//
//  BlobStoreTests.swift
//  maxmailinTests
//
//  S3a of SIZE_LIMITS_DESIGN.md. The blob tier exists because SQLite's default
//  maximum BLOB length is also its maximum ROW size (1 GB), so a message above
//  that cannot be stored in `email_bodies.raw` at all.
//
//  The properties that matter for evidence, pinned here:
//   • content addressing: identical bodies stored once, and a stored body can
//     be verified against its own name
//   • tamper detection: a modified blob fails verification rather than being
//     served as if it were the original
//   • range reads: a part can be read without reading the message
//   • streaming writes: a large body is never held in memory
//   • orphan collection never deletes a referenced blob
//

import Testing
import Foundation
@testable import maxmailin

private func makeStore() -> BlobStore {
    BlobStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("blobs-\(UUID().uuidString)", isDirectory: true))
}

@Suite("Blob store (S3a)")
struct BlobStoreTests {

    // MARK: Content addressing

    @Test("A stored blob round-trips byte-for-byte")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let body = Data("From: a@b\r\n\r\nthe original bytes".utf8)
        let reference = try store.write(body)

        #expect(reference.length == Int64(body.count))
        #expect(reference.digest.count == 64)
        #expect(try store.read(reference) == body)
    }

    @Test("Identical content is stored once")
    func deduplicatesByContent() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let body = Data(repeating: 0x41, count: 4096)
        let first = try store.write(body)
        let second = try store.write(body)

        #expect(first == second)
        #expect(store.storedDigests().count == 1, "the same body is not stored twice")
    }

    @Test("Different content gets different addresses")
    func distinctContentDistinctBlobs() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let a = try store.write(Data("alpha".utf8))
        let b = try store.write(Data("beta".utf8))

        #expect(a.digest != b.digest)
        #expect(store.storedDigests().count == 2)
    }

    // MARK: Tamper detection

    @Test("A modified blob fails verification instead of being served")
    func tamperIsDetected() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let reference = try store.write(Data("evidence body".utf8))
        // Modify the stored file behind the store's back.
        try Data("tampered body".utf8).write(to: store.url(for: reference.digest))

        #expect(throws: BlobStoreError.self) { _ = try store.read(reference) }
        // The unverified read still returns bytes — callers that opt out must
        // know they are opting out.
        #expect(try store.read(reference, verify: false) == Data("tampered body".utf8))
    }

    @Test("A missing blob is a named error, not empty data")
    func missingBlobIsAnError() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let phantom = BlobReference(digest: String(repeating: "a", count: 64), length: 10)
        #expect(!store.exists(phantom))
        #expect(throws: BlobStoreError.self) { _ = try store.read(phantom) }
    }

    // MARK: Range reads

    @Test("A byte range is readable without reading the whole body")
    func rangeRead() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // 0…255 repeated, so every offset has a predictable value.
        var bytes: [UInt8] = []
        for i in 0..<(64 * 1024) { bytes.append(UInt8(i % 256)) }
        let reference = try store.write(Data(bytes))

        let slice = try store.read(reference, offset: 1000, length: 256)
        #expect(slice.count == 256)
        #expect(Array(slice) == (0..<256).map { UInt8((1000 + $0) % 256) })
    }

    @Test("An out-of-bounds range is refused rather than truncated silently")
    func rangeBoundsAreChecked() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let reference = try store.write(Data(repeating: 0x7A, count: 1024))
        #expect(throws: BlobStoreError.self) {
            _ = try store.read(reference, offset: 1000, length: 500)
        }
        #expect(throws: BlobStoreError.self) {
            _ = try store.read(reference, offset: -1, length: 10)
        }
    }

    // MARK: Streaming writes

    @Test("A large body is stored by streaming, and matches the in-memory digest")
    func streamingWriteMatchesMemoryWrite() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // 12 MiB — above the 8 MiB inline threshold, so a realistic external
        // case, and large enough that chunking actually happens.
        var bytes = Data(capacity: 12 * 1_048_576)
        for i in 0..<(12 * 1_048_576) { bytes.append(UInt8(i % 251)) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-src-\(UUID().uuidString).bin")
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let streamed = try store.write(contentsOf: source, chunkSize: 1_048_576)
        #expect(streamed.length == Int64(bytes.count))

        // The streamed digest must equal what an in-memory write would produce.
        let other = makeStore()
        defer { try? FileManager.default.removeItem(at: other.root) }
        let inMemory = try other.write(bytes)
        #expect(streamed.digest == inMemory.digest)

        // And it reads back identical.
        #expect(try store.read(streamed) == bytes)
    }

    @Test("Streaming the same content twice keeps one copy")
    func streamingDeduplicates() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-dup-\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 3 * 1_048_576).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = try store.write(contentsOf: source)
        let second = try store.write(contentsOf: source)

        #expect(first == second)
        #expect(store.storedDigests().count == 1)
        // No staging files left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?
            .filter { $0.hasPrefix(".tmp-") } ?? []
        #expect(leftovers.isEmpty, "staging files must not accumulate")
    }

    // MARK: Orphan collection

    @Test("Orphan collection deletes unreferenced blobs and keeps referenced ones")
    func orphanCollection() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let keep = try store.write(Data("still referenced".utf8))
        let drop = try store.write(Data("no row points here".utf8))

        let result = store.collectOrphans(referenced: [keep.digest])
        #expect(result.deleted == 1)
        #expect(result.bytesReclaimed > 0)
        #expect(store.exists(keep), "a referenced blob must never be collected")
        #expect(!store.exists(drop))
    }

    @Test("Collecting with nothing referenced empties the store; with all referenced, nothing moves")
    func orphanCollectionExtremes() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let a = try store.write(Data("a".utf8))
        let b = try store.write(Data("b".utf8))

        #expect(store.collectOrphans(referenced: [a.digest, b.digest]).deleted == 0)
        #expect(store.storedDigests().count == 2)

        #expect(store.collectOrphans(referenced: []).deleted == 2)
        #expect(store.storedDigests().isEmpty)
    }

    @Test("Total bytes reflects what is stored, for the storage planner")
    func totalBytesIsUsable() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        #expect(store.totalBytes() == 0)
        _ = try store.write(Data(repeating: 1, count: 2048))
        _ = try store.write(Data(repeating: 2, count: 4096))
        #expect(store.totalBytes() >= 6144)
    }

    // MARK: Layout

    @Test("Blobs fan out by digest prefix so no directory grows unbounded")
    func directoryFanOut() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let reference = try store.write(Data("fan out".utf8))
        let path = store.url(for: reference.digest)

        #expect(path.lastPathComponent == reference.digest)
        #expect(path.deletingLastPathComponent().lastPathComponent
                == String(reference.digest.prefix(2)))
    }

    @Test("The inline threshold is the documented 8 MiB boundary")
    func inlineThreshold() {
        #expect(BlobStore.inlineThresholdBytes == 8 * 1_048_576)
    }
}
