//
//  OffsetImportEngine.swift
//  mailin
//
//  S4, the import side: turn a scan into messages, in bounded memory.
//
//  The decision this engine makes, per message, is the whole point:
//
//   • **At or under `fullParseCeilingBytes`** the range is read and handed to
//     the EXISTING `MBOXParser.processRawMessage`. Output is byte-for-byte the
//     same as the streaming parser's, so switching the capability on does not
//     change how ordinary mail is imported. That matters more than elegance:
//     99.99% of messages take the proven path.
//
//   • **Above it** the message is imported from its HEADERS plus a locator.
//     No body is decoded, no MIME tree is built, `rawSource` is left empty and
//     the locator records where the bytes are. Today such a message is counted
//     as `oversized_message` and SKIPPED — it does not enter the archive at
//     all. Importing it with an honest "body not decoded at import" marker is
//     strictly better than losing it, and S5's locator reads then serve its
//     attachments and exports from the original bytes.
//
//  What this deliberately does NOT claim: a 1.5 GB message does not get a
//  searchable body or a parsed attachment list at import time. It gets an
//  entry, its headers, and a pointer to its bytes. Pretending otherwise would
//  mean either decoding it (the memory ceiling we are removing) or fabricating
//  metadata. The message is marked so no surface can mistake it for fully
//  processed.
//
//  Shipped behind `Capability.offsetParser`, OFF by default.
//

import Foundation
import CryptoKit
import os.log

private let offsetImportLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin",
                                     category: "OffsetImport")

struct OffsetImportEngine: Sendable {

    /// Bump when message extraction or ORDERING changes — resume checkpoints
    /// bound to the previous version are then invalidated rather than
    /// silently resumed against a different ordering. Same contract as
    /// `MBOXParser.parserVersion`, tracked separately because this engine's
    /// ordering is genuinely different (see `ParserFactory
    /// .offsetParserIdentity()`).
    static let engineVersion = 1

    /// Messages at or below this size take the existing full-fidelity path.
    /// Set to the old hard ceiling, so the change is purely additive: every
    /// message that imports today still imports the same way, and the ones
    /// that are currently DROPPED are the ones that behave differently.
    var fullParseCeilingBytes: Int64 = 100 * 1_048_576

    var scanner = OffsetMBOXScanner()

    /// The marker put on a message whose body was not decoded at import, so
    /// no surface can present it as fully processed.
    static let deferredBodyMarker = "Body not decoded at import (message exceeds the full-parse ceiling); "
        + "its original bytes are indexed and readable on demand."

    /// One imported message plus where its bytes live.
    struct Imported: Sendable {
        var email: MBOXParser.RawEmail
        var locator: MessageLocator
        /// False when only headers were parsed.
        var bodyWasDecoded: Bool
        /// Where each MIME part's bytes are, so an attachment can later be
        /// read without its siblings.
        ///
        /// Populated only on the under-ceiling path, where the message's bytes
        /// have already been read and scanning them costs no extra I/O. A
        /// header-only import leaves this empty on purpose: finding its parts
        /// would mean a linear pass over the very body S4 declined to read.
        /// Empty means "use the whole-message path", never "no attachments".
        var parts: [PartLocator] = []
    }

    // MARK: - Import

    /// Scans `fileURL` and emits messages in batches bounded by `envelope`.
    ///
    /// Returns the same source-scoped recovery report shape as the streaming
    /// parser, so the coordinator, the receipt and the reconciler need no
    /// special case for which engine ran.
    @discardableResult
    func importMessages(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int = 200,
        envelopeProvider: (@Sendable () async -> BatchEnvelope)? = nil,
        retainAttachmentBytes: Bool = true,
        sourceDigest: String? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([Imported]) async throws -> Void
    ) async throws -> MBOXParser.ParseRecoveryReport {

        var envelope = await envelopeProvider?()
            ?? BatchEnvelope(maxMessages: batchSize, maxBytes: Int.max)

        var batch: [Imported] = []
        batch.reserveCapacity(batchSize)
        var batchBytes = 0
        var total = 0
        var parsed = 0
        var failed = 0
        var categories: [String: Int] = [:]
        let reader = LocatorReader()   // same file, same run — no provenance claim needed

        // The scanner awaits this callback, so the scan cannot outrun the
        // consumer and locators are never accumulated for the whole file.
        // `collect: false` is what keeps a 500 GB source from turning its
        // index into the new memory ceiling.
        var scanError: Error?
        do {
            _ = try await scanner.scan(fileURL: fileURL, collect: false, onLocator: { rawLocator, headers in
                total += 1
                var locator = rawLocator
                locator.sourceDigest = sourceDigest

                do {
                    let imported = try build(locator: locator,
                                             headers: headers,
                                             senderEmail: senderEmail,
                                             retainAttachmentBytes: retainAttachmentBytes,
                                             reader: reader)
                    batch.append(imported)
                    // Saturating add: a single message can exceed Int.max on
                    // no real platform, but the batch bound must not wrap.
                    batchBytes = batchBytes.addingReportingOverflow(
                        Int(clamping: locator.byteCount)).partialValue
                    parsed += 1
                } catch {
                    // Counted, categorised, returned — never silently dropped.
                    failed += 1
                    categories["offset parse error", default: 0] += 1
                    offsetImportLog.error("""
                        message \(locator.ordinal) at \(locator.messageRange.offset) failed: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                }

                if batch.count >= envelope.maxMessages || batchBytes >= envelope.maxBytes {
                    try await onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    batchBytes = 0
                    // Re-ask after every flush, so pressure appearing mid-file
                    // shrinks the NEXT batch rather than the next file.
                    if let envelopeProvider { envelope = await envelopeProvider() }
                }
            }, onProgress: onProgress)
        } catch {
            scanError = error
        }

        // Whatever was already batched is real mail and is delivered before
        // the error is rethrown, so a mid-file I/O failure yields a PARTIAL
        // import with an accurate count rather than nothing at all.
        if !batch.isEmpty {
            try await onBatch(batch)
            batch.removeAll(keepingCapacity: true)
        }

        if let scanError { throw scanError }

        return MBOXParser.ParseRecoveryReport(
            totalMessages: total, successfullyParsed: parsed,
            failed: failed, errorCategories: categories)
    }

    // MARK: - Parts

    /// Part ranges for a message whose bytes are already in hand.
    ///
    /// `messageData` must be the bytes of `locator.messageRange` exactly, so
    /// the body's position inside it is a subtraction rather than a search.
    /// Returns empty on anything inconsistent: a wrong range is worse than no
    /// range, because the caller would read the wrong bytes and believe them.
    private static func scanParts(messageData: Data,
                                  locator: MessageLocator,
                                  headers: [String: String],
                                  messageID: UUID) -> [PartLocator] {
        guard messageData.count == Int(locator.messageRange.length) else { return [] }
        let bodyStart = Int(locator.bodyRange.offset - locator.messageRange.offset)
        guard bodyStart >= 0, bodyStart <= messageData.count else { return [] }
        let bodyData = messageData.subdata(in: bodyStart..<messageData.count)
        return MIMEPartScanner.parts(bodyData: bodyData,
                                     bodyOffset: locator.bodyRange.offset,
                                     topHeaders: headers,
                                     messageID: messageID)
    }

    // MARK: - One message

    private func build(locator: MessageLocator,
                       headers: [String: String],
                       senderEmail: String,
                       retainAttachmentBytes: Bool,
                       reader: LocatorReader) throws -> Imported {

        if locator.byteCount <= fullParseCeilingBytes {
            // The proven path, byte-identical to the streaming parser.
            let data = try reader.read(locator.messageRange, from: locator.sourcePath)
            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
            let email = try MBOXParser.processRawMessage(
                raw, senderEmail: senderEmail,
                retainAttachmentBytes: retainAttachmentBytes)

            // Part ranges come from `data` — the ORIGINAL bytes — not from
            // `raw`. Re-encoding the String would shift every offset whenever
            // the source was not UTF-8 (latin-1 high bytes expand to two), and
            // a shifted range corrupts the attachment it points at.
            let parts = Self.scanParts(messageData: data, locator: locator,
                                       headers: email.headers, messageID: email.id)
            return Imported(email: email, locator: locator,
                            bodyWasDecoded: true, parts: parts)
        }

        // Header-only import. This message would otherwise not exist in the
        // archive at all.
        var mapped = headers
        if mapped["Message-ID"] == nil, let alternative = headers["Message-Id"] {
            mapped["Message-ID"] = alternative
        }

        let email = MBOXParser.RawEmail(
            headers: mapped,
            rawSource: "",                      // deliberately empty: the bytes are in the source
            messageType: "email",
            attachments: [],                    // not enumerated without decoding
            timestamp: mapped["Date"] ?? "",
            domains: Self.domains(in: mapped),
            plainBody: "",
            htmlBody: "",
            mimeRoot: nil,
            mimeSummary: "Not parsed at import (\(ByteCountFormatter.string(fromByteCount: locator.byteCount, countStyle: .file)))",
            mimeDiagnostics: [Self.deferredBodyMarker],
            threadID: mapped["Message-ID"],
            inReplyTo: mapped["In-Reply-To"],
            references: mapped["References"]?.split(separator: " ").map(String.init),
            tags: [],
            anomalies: [Self.deferredBodyMarker]
        )
        offsetImportLog.notice("""
            imported message \(locator.ordinal) header-only \
            (\(locator.byteCount) bytes) — previously it would have been skipped as oversized
            """)
        return Imported(email: email, locator: locator, bodyWasDecoded: false)
    }

    private static func domains(in headers: [String: String]) -> [String] {
        var found = Set<String>()
        for key in ["From", "To", "Cc", "Reply-To"] {
            guard let value = headers[key] else { continue }
            for piece in value.components(separatedBy: CharacterSet(charactersIn: ",;<> ")) {
                guard let at = piece.firstIndex(of: "@") else { continue }
                let domain = piece[piece.index(after: at)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ">,; "))
                    .lowercased()
                if domain.contains(".") { found.insert(domain) }
            }
        }
        return Array(found).sorted()
    }

    // MARK: - Source digest

    /// SHA-256 of the whole source, streamed. The locator records it so a
    /// later read can prove it hit the same bytes; without it a moved or
    /// edited file would be read silently.
    static func digest(of fileURL: URL, chunkSize: Int = 4 * 1_048_576) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw LocatorReadError.sourceMissing(fileURL.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: chunkSize) }
            catch { throw LocatorReadError.ioError(error.localizedDescription) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
