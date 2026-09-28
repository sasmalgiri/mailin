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

    /// Chunk-wise mboxrd UNquoting — the inverse of `StreamingQuoter`, with
    /// the same line-boundary carry so a `>From ` split across two reads is
    /// still seen at its line start.
    struct StreamingUnquoter {
        let enabled: Bool
        private var carry: [UInt8] = []

        init(enabled: Bool) { self.enabled = enabled }

        mutating func process(_ chunk: Data) -> Data {
            guard enabled else { return chunk }
            let buffer = carry + Array(chunk)
            var cut = buffer.count
            while cut > 0, buffer[cut - 1] != MBOXRecordBuilder.lf, buffer[cut - 1] != MBOXRecordBuilder.cr { cut -= 1 }
            if cut > 0, buffer[cut - 1] == MBOXRecordBuilder.cr { cut -= 1 }
            if cut == 0, buffer.count > 1_048_576 { cut = buffer.count }
            let complete = Array(buffer[..<cut])
            carry = Array(buffer[cut...])
            return Data(MBOXRecordBuilder.unquoteFromLines(bytes: complete))
        }

        mutating func finish() -> Data {
            let out = enabled ? MBOXRecordBuilder.unquoteFromLines(bytes: carry) : carry
            carry = []
            return Data(out)
        }
    }
}

/// Synchronous located-message writer, for the two legacy UI export loops
/// that cannot await. Reads the locator on its own read-only connection.
enum RawMessageFile {

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
    static func write(located locator: MessageLocator, to url: URL, chunkSize: Int = 1_048_576) throws -> RawMessageResult {
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
    /// than yielding an empty message.
    func streamRawMessage(for email: MBOXParser.RawEmail,
                          chunkSize: Int = 1_048_576,
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
    func rawMessageData(for email: MBOXParser.RawEmail) async throws -> Data {
        var out = Data()
        _ = try await streamRawMessage(for: email) { out.append($0) }
        return out
    }

    /// Writes the message's original bytes to `url`; a failure leaves no file.
    @discardableResult
    func writeRawMessage(for email: MBOXParser.RawEmail, to url: URL) async throws -> RawMessageResult {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        let result = try await streamRawMessage(for: email) { try handle.write(contentsOf: $0) }
        succeeded = true
        return result
    }
}
