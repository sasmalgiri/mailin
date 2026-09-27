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
}

extension MBOXRecordBuilder {

    /// Chunk-wise mboxrd quoting with exactly the result `quoteFromLines`
    /// gives on the whole text. A partial last line is carried to the next
    /// chunk so a `From ` split across two reads is still seen at its line
    /// start; a trailing CR is held back in case its LF arrives next.
    struct StreamingQuoter {
        let enabled: Bool
        private var carry: [UInt8] = []
        /// The last four bytes emitted, for the record-terminator decision.
        private(set) var tail: [UInt8] = []

        init(enabled: Bool) { self.enabled = enabled }

        mutating func process(_ chunk: Data) -> Data {
            guard enabled else { remember(chunk); return chunk }
            let buffer = carry + Array(chunk)
            var cut = buffer.count
            while cut > 0, buffer[cut - 1] != MBOXRecordBuilder.lf, buffer[cut - 1] != MBOXRecordBuilder.cr { cut -= 1 }
            if cut > 0, buffer[cut - 1] == MBOXRecordBuilder.cr { cut -= 1 }
            // A line longer than a whole chunk cannot begin with `From ` past
            // its first bytes; flush it rather than grow the carry unbounded.
            if cut == 0, buffer.count > 1_048_576 { cut = buffer.count }
            let complete = Array(buffer[..<cut])
            carry = Array(buffer[cut...])
            let out = MBOXRecordBuilder.quoteFromLines(bytes: complete)
            remember(out)
            return Data(out)
        }

        mutating func finish() -> Data {
            let out = enabled ? MBOXRecordBuilder.quoteFromLines(bytes: carry) : carry
            carry = []
            remember(out)
            return Data(out)
        }

        /// What the record must be followed by so that it ends with exactly
        /// one blank line (RFC 4155): nothing, one newline, or two.
        var recordTerminator: Data {
            let lf = MBOXRecordBuilder.lf, cr = MBOXRecordBuilder.cr
            if tail.suffix(2) == [lf, lf] || tail == [cr, lf, cr, lf] { return Data() }
            if tail.last == lf { return Data([lf]) }
            return Data([lf, lf])
        }

        private mutating func remember<C: Collection>(_ bytes: C) where C.Element == UInt8 {
            tail = Array((tail + Array(bytes.suffix(4))).suffix(4))
        }
    }
}

extension ArchiveExportService {

    /// Streams `plan.range` from the source through `write` in 1 MiB chunks.
    /// Every byte goes through the same `write` as the String path, so the
    /// export's SHA-256 covers the streamed record too.
    static func streamRecord(_ plan: RawStreamPlan,
                             chunkSize: Int = 1_048_576,
                             write: (Data) throws -> Void) throws {
        let path = plan.sourcePath
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
        try write(quoter.finish())
        try write(quoter.recordTerminator)
    }

    /// The streaming plan for a message whose bytes are located rather than
    /// stored; nil when the message has stored raw MIME (the String path
    /// handles it) or no locator (the synthesized fallback handles it).
    func locatorStreamPlan(for email: MBOXParser.RawEmail) async throws -> RawStreamPlan? {
        guard email.rawSource.isEmpty,
              let locator = try await archive.messageLocator(for: email.id) else { return nil }
        // The source's own envelope line when it has one, else one built
        // from the message's sender and date.
        var prefix = MBOXRecordBuilder.envelopeLine(for: email)
        if let envelopeRange = locator.envelopeRange,
           let data = try? LocatorReader().read(envelopeRange, from: locator.sourcePath),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           let envelope = MBOXRecordBuilder.envelopeLine(in: text), !envelope.contains("MAILER-DAEMON") {
            prefix = envelope + "\n"
        }
        let start = locator.headerRange.offset
        let range = ByteRange(offset: start, length: max(0, locator.messageRange.end - start))
        return RawStreamPlan(prefix: prefix, sourcePath: locator.sourcePath, range: range,
                             quoteFromLines: locator.envelopeRange == nil)
    }
}
