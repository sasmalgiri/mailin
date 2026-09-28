//
//  RawMessageAccess.swift
//  ArchiveCore
//
//  Audit F05 (2026-09-28): one way to get a message's ORIGINAL BYTES, shared
//  by every export that promises them. A message above the full-parse
//  ceiling is imported from its headers with a `MessageLocator` and an empty
//  `rawSource`; before this file, EML export, production and the sealed case
//  bundle each read `rawSource` directly and so wrote — and in one case
//  hashed and sealed — nothing, while reporting success. Only the MBOX export
//  had its own streaming path.
//
//  Contract: `stored` bytes are the raw MIME the archive holds; `located`
//  bytes are streamed from the source with exactly the normalisation the
//  offset engine applies when it DOES store a message — the record's own
//  envelope line kept verbatim, RFC 4155 mboxrd quoting undone on the rest —
//  so a located message's bytes equal what a full parse would have stored
//  (`DeferredMessageIntegrityTests` proves this byte for byte). `unavailable`
//  is an ERROR for every caller — never an empty message.
//

import Foundation
import CryptoKit

/// Where a message's original bytes can be read from right now.
enum RawMessageSource: Sendable {
    case stored(String)
    case located(MessageLocator)
    case unavailable(String)

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

enum RawMessageError: LocalizedError, Equatable {
    case contentUnavailable(subject: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .contentUnavailable(let subject, let reason):
            return "The content of “\(subject)” is not available: \(reason)."
        }
    }
}

struct RawMessageResult: Sendable, Equatable {
    var bytes: Int
    var sha256Hex: String
}

extension MBOXRecordBuilder {

    /// Chunk-wise mboxrd UNquoting — the inverse of `StreamingQuoter`, built
    /// on the same byte state machine (`StreamingFromLineFilter`), so a
    /// `>From ` is recognised only at a real line start whatever the chunking
    /// and however long the line (recheck R7).
    struct StreamingUnquoter {
        let enabled: Bool
        private var filter: StreamingFromLineFilter

        init(enabled: Bool) {
            self.enabled = enabled
            self.filter = StreamingFromLineFilter(mode: .unquote, enabled: enabled)
        }

        mutating func process(_ chunk: Data) -> Data { filter.process(chunk) }
        mutating func finish() -> Data { filter.finish() }
    }
}

/// Audit F04 (2026-09-28): an export that streams bytes from a source file
/// proves, once per source per run, that the file on disk is the file that
/// was imported — its SHA-256 matches the digest recorded on the locator.
/// Without this a same-length edit to the source changed later exports
/// silently, each with a fresh, valid artifact hash. One ledger lives for one
/// export run; the hash is computed off the main actor.
final class SourceVerificationLedger: @unchecked Sendable {
    private var verifiedKeys: Set<String> = []
    private var verified: Set<String> = []
    private var unverified: Set<String> = []
    private let lock = NSLock()

    init() {}

    /// Paths this run has verified so far (for receipts and tests).
    var verifiedPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return verified
    }

    /// Paths that could NOT be verified because their locator carries no
    /// digest (imported before digests were recorded). Reported, never
    /// silently treated as verified (recheck R4).
    var unverifiedPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return unverified
    }

    /// Recheck R4: the cache key is the file's canonical identity PLUS the
    /// digest the locator expects PLUS the file's current size and
    /// modification date. Two locators that recorded different digests for
    /// the same path each get their own verification, and a file modified
    /// after a verification is re-verified because its key changed.
    static func cacheKey(for locator: MessageLocator) -> String {
        let path = ArchiveRelocator.canonicalPath(URL(fileURLWithPath: locator.sourcePath))
        let attributes = try? FileManager.default.attributesOfItem(atPath: locator.sourcePath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(path)|\(locator.sourceDigest ?? "")|\(size)|\(modified)"
    }

    /// Throws `LocatorReadError.digestMismatch` when the source has changed
    /// since import, `.sourceMissing` when it is gone. A locator without a
    /// digest is recorded in `unverifiedPaths` and passes.
    func verify(_ locator: MessageLocator) async throws {
        guard locator.hasVerifiableSource else { noteUnverifiable(locator); return }
        let key = Self.cacheKey(for: locator)
        lock.lock()
        let done = verifiedKeys.contains(key)
        lock.unlock()
        if done { return }
        try await Task.detached(priority: .userInitiated) {
            try LocatorReader().verifySource(locator)
        }.value
        record(key, locator)
    }

    /// Same contract, on the calling thread — for the synchronous legacy
    /// paths (`RawMessageFile`), which run off the main actor.
    func verifySync(_ locator: MessageLocator) throws {
        guard locator.hasVerifiableSource else { noteUnverifiable(locator); return }
        let key = Self.cacheKey(for: locator)
        lock.lock()
        let done = verifiedKeys.contains(key)
        lock.unlock()
        if done { return }
        try LocatorReader().verifySource(locator)
        record(key, locator)
    }

    private func record(_ key: String, _ locator: MessageLocator) {
        lock.lock()
        verifiedKeys.insert(key)
        verified.insert(locator.sourcePath)
        lock.unlock()
    }

    private func noteUnverifiable(_ locator: MessageLocator) {
        lock.lock()
        unverified.insert(locator.sourcePath)
        lock.unlock()
    }
}

/// Synchronous located-message writer, for the two legacy UI export loops
/// that cannot await. Reads the locator on its own read-only connection.
/// Every write verifies the source first (R4) through a process-wide ledger
/// whose key includes the file's size and modification date, so a run over
/// many located messages hashes each unchanged source once.
enum RawMessageFile {

    nonisolated(unsafe) static let ledger = SourceVerificationLedger()

    /// The message's original bytes, if it has any: stored raw MIME, or a
    /// locator whose source file is present. Nil means an export must fail or
    /// exclude the message — never write a stub for it.
    static func locator(for email: MBOXParser.RawEmail,
                        storeDirectory: URL = SQLiteEmailStore.productionDirectory) -> MessageLocator? {
        guard email.rawSource.isEmpty,
              let locator = SQLiteEmailStore.locatorSnapshot(emailID: email.id, storeDirectory: storeDirectory),
              FileManager.default.fileExists(atPath: locator.sourcePath) else { return nil }
        return locator
    }

    /// Streams a located message into `url` (its envelope line kept, mboxrd
    /// unquoted — what a full parse stores). On failure the partial file is
    /// removed.
    @discardableResult
    static func write(located locator: MessageLocator, to url: URL, chunkSize: Int = 1_048_576,
                      verifying ledger: SourceVerificationLedger? = RawMessageFile.ledger) throws -> RawMessageResult {
        if let ledger { try ledger.verifySync(locator) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        var digest = SHA256()
        var total = 0
        try stream(located: locator, chunkSize: chunkSize) { chunk in
            try handle.write(contentsOf: chunk)
            digest.update(data: chunk)
            total += chunk.count
        }
        succeeded = true
        return RawMessageResult(bytes: total, sha256Hex: hex(digest.finalize()))
    }

    /// The located message's bytes through `sink`, normalised exactly as
    /// `OffsetImportEngine.build` normalises a message it stores: the whole
    /// record including its envelope line (which never starts with `>`, so the
    /// unquoter leaves it alone), mboxrd quoting undone when the record came
    /// from an mbox.
    static func stream(located locator: MessageLocator, chunkSize: Int = 1_048_576,
                       sink: (Data) throws -> Void) throws {
        let range = locator.messageRange
        var unquoter = MBOXRecordBuilder.StreamingUnquoter(enabled: locator.envelopeRange != nil)
        try LocatorReader().stream(range, from: locator.sourcePath, chunkSize: chunkSize) { chunk in
            let out = unquoter.process(chunk)
            if !out.isEmpty { try sink(out) }
        }
        let tail = unquoter.finish()
        if !tail.isEmpty { try sink(tail) }
    }

    static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension ArchiveDataService {

    /// Where `email`'s original bytes are right now.
    func rawMessageSource(for email: MBOXParser.RawEmail) async -> RawMessageSource {
        if !email.rawSource.isEmpty { return .stored(email.rawSource) }
        guard let locator = try? await messageLocator(for: email.id) else {
            return .unavailable("the archive holds neither its content nor a record of the original file")
        }
        guard FileManager.default.fileExists(atPath: locator.sourcePath) else {
            return .unavailable("the original file is no longer at \(locator.sourcePath)")
        }
        return .located(locator)
    }

    /// Streams the original bytes of `email` through `sink` and returns their
    /// count and SHA-256. Throws `RawMessageError.contentUnavailable` rather
    /// than yielding an empty message. With a `ledger`, a located message's
    /// source is verified against its recorded digest first (F04).
    func streamRawMessage(for email: MBOXParser.RawEmail,
                          chunkSize: Int = 1_048_576,
                          ledger: SourceVerificationLedger? = nil,
                          sink: (Data) throws -> Void) async throws -> RawMessageResult {
        let subject = email.headers["Subject"] ?? "(no subject)"
        var digest = SHA256()
        var total = 0
        switch await rawMessageSource(for: email) {
        case .stored(let raw):
            let data = Data(raw.utf8)
            digest.update(data: data)
            total = data.count
            try sink(data)
        case .located(let locator):
            if let ledger { try await ledger.verify(locator) }
            try RawMessageFile.stream(located: locator, chunkSize: chunkSize) { chunk in
                digest.update(data: chunk)
                total += chunk.count
                try sink(chunk)
            }
        case .unavailable(let reason):
            throw RawMessageError.contentUnavailable(subject: subject, reason: reason)
        }
        return RawMessageResult(bytes: total, sha256Hex: RawMessageFile.hex(digest.finalize()))
    }

    /// The whole message in memory. For a located message this is the
    /// message's own size; callers that can stream should use
    /// `streamRawMessage` or `writeRawMessage` instead.
    func rawMessageData(for email: MBOXParser.RawEmail, ledger: SourceVerificationLedger? = nil) async throws -> Data {
        var out = Data()
        _ = try await streamRawMessage(for: email, ledger: ledger) { out.append($0) }
        return out
    }

    /// Writes the message's original bytes to `url`; a failure leaves no file.
    @discardableResult
    func writeRawMessage(for email: MBOXParser.RawEmail, to url: URL,
                         ledger: SourceVerificationLedger? = nil) async throws -> RawMessageResult {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        let result = try await streamRawMessage(for: email, ledger: ledger) { try handle.write(contentsOf: $0) }
        succeeded = true
        return result
    }
}
