//
//  MBOXStreamingExport.swift
//  ArchiveCore
//
//  S5 export half: a message whose bytes are LOCATED rather than stored (the
//  offset engine's header-only import of a message above the full-parse
//  ceiling — `rawSource` empty, a `MessageLocator` on file) is exported by
//  streaming its bytes from the source in bounded chunks. Before this, such a
//  message left the exporter as a headers-only stub: the 1.1 GB executed row
//  (`LargeMessageBlobTests`) came back as 427 bytes (found 2026-09-27).
//
//  Fidelity rule: bytes from an mbox source are already mboxrd-escaped and
//  are streamed verbatim; bytes from a bare .eml source are quoted on the
//  way out, line-aware across chunk boundaries.
//

import Foundation

/// How to write one record from its source instead of from a String.
struct RawStreamPlan: Sendable {
    /// Written before the bytes — the record's envelope line.
    var prefix: String
    var sourcePath: String
    /// The message bytes to stream: first header byte to the end of the
    /// record (the source's own envelope line excluded).
    var range: ByteRange
    /// True when the source is NOT an mbox (no container escaping present).
    var quoteFromLines: Bool
    /// Fourth review Q1: the verified locator travels with the plan so the
    /// stream can prove the source is still what was verified — before the
    /// first byte and after the last.
    var locator: MessageLocator? = nil
}

extension MBOXRecordBuilder {

    /// Chunk-wise mboxrd quoting with exactly the result `quoteFromLines`
    /// gives on the whole text, over any chunk boundaries and any line length
    /// (recheck R7: the previous carry-and-flush version lost line-start
    /// state on lines above 1 MiB). A thin wrapper over
    /// `StreamingFromLineFilter` that adds the record-terminator decision.
    struct StreamingQuoter {
        let enabled: Bool
        private var filter: StreamingFromLineFilter

        init(enabled: Bool) {
            self.enabled = enabled
            self.filter = StreamingFromLineFilter(mode: .quote, enabled: enabled)
        }

        mutating func process(_ chunk: Data) -> Data { filter.process(chunk) }
        mutating func finish() -> Data { filter.finish() }

        /// The last four bytes emitted.
        var tail: [UInt8] { filter.tail }

        /// What the record must be followed by so that it ends with exactly
        /// one blank line (RFC 4155): nothing, one newline, or two.
        var recordTerminator: Data {
            let lf = MBOXRecordBuilder.lf, cr = MBOXRecordBuilder.cr
            let tail = filter.tail
            if tail.suffix(2) == [lf, lf] || tail == [cr, lf, cr, lf] { return Data() }
            if tail.last == lf { return Data([lf]) }
            return Data([lf, lf])
        }
    }
}

extension ArchiveExportService {

    /// Streams `plan.range` from the source through `write` in 1 MiB chunks.
    /// Every byte goes through the same `write` as the String path, so the
    /// export's SHA-256 covers the streamed record too.
    static func streamRecord(_ plan: RawStreamPlan,
                             chunkSize: Int = 1_048_576,
                             ledger: SourceVerificationLedger? = nil,
                             write: (Data) throws -> Void) throws {
        let path = plan.sourcePath
        // Q1: the same pre/post change check `RawMessageFile.stream` makes.
        // A source that changed between verification and this read, or
        // during it, throws — and the caller cuts its output back.
        if let locator = plan.locator { try ledger?.assertUnchanged(locator) }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocatorReadError.sourceMissing(path)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        guard plan.range.offset >= 0, plan.range.length >= 0, plan.range.end <= size else {
            throw LocatorReadError.rangeUnresolvable(plan.range, fileSize: size)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw LocatorReadError.ioError("cannot open \(path)")
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(plan.range.offset))

        var quoter = MBOXRecordBuilder.StreamingQuoter(enabled: plan.quoteFromLines)
        var remaining = Int(plan.range.length)
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                // The file shrank under us: a short record must be an error,
                // never a record that looks complete.
                throw LocatorReadError.rangeUnresolvable(plan.range, fileSize: Int64(Int(plan.range.length) - remaining))
            }
            remaining -= chunk.count
            try write(quoter.process(chunk))
        }
        // Checked BEFORE the tail is committed: a change during the read
        // means the bytes already written are not the verified bytes.
        if let locator = plan.locator { try ledger?.assertUnchanged(locator) }
        try write(quoter.finish())
        try write(quoter.recordTerminator)
    }

    /// The streaming plan for a message whose bytes are located rather than
    /// stored; nil when the message has stored raw MIME (the String path
    /// handles it) or no locator (the synthesized fallback handles it).
    func locatorStreamPlan(for email: MBOXParser.RawEmail) async throws -> RawStreamPlan? {
        guard email.rawSource.isEmpty,
              let locator = try await archive.messageLocator(for: email.id) else { return nil }
        // Audit F04: the source is verified against its recorded digest once
        // per export run before any of its bytes are streamed.
        try await sourceLedger.verify(locator)
        // The source's own envelope line when it has one, else one built
        // from the message's sender and date.
        var prefix = MBOXRecordBuilder.envelopeLine(for: email)
        if let envelopeRange = locator.envelopeRange,
           let data = try? LocatorReader().read(envelopeRange, from: locator.sourcePath),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           let envelope = MBOXRecordBuilder.envelopeLine(in: text), !envelope.contains("MAILER-DAEMON") {
            prefix = envelope + "\n"
        }
        // Q1: the envelope read above relied on the verification too.
        try sourceLedger.assertUnchanged(locator)
        let start = locator.headerRange.offset
        let range = ByteRange(offset: start, length: max(0, locator.messageRange.end - start))
        return RawStreamPlan(prefix: prefix, sourcePath: locator.sourcePath, range: range,
                             quoteFromLines: locator.envelopeRange == nil, locator: locator)
    }
}
