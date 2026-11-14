//
//  StreamedBodyIndex.swift
//  ArchiveCore
//
//  R5 (audit bf1a5b9; owner 2026-11-08: "there should be no limit at all"):
//  a message of ANY size has its text in the search index.
//
//  Background. The offset engine imports a message above
//  `OffsetImportEngine.fullParseCeilingBytes` (100 MiB) from its headers plus
//  a locator — the bytes stay in the original file and are exported byte for
//  byte — because decoding it whole would need the whole message in memory.
//  Until R5 such a message's text was therefore never searchable: the Limits
//  screen listed "Single message above 100 MiB … its text is not searchable".
//
//  What this file does instead. The message is read from its original file in
//  slices (1 MiB by default) and walked as a MIME stream: boundaries, part
//  headers, transfer encodings (base64, quoted-printable, 7/8-bit) and
//  charsets are decoded line by line; the text of its text parts (plain text,
//  or the HTML's text where a message has no plain alternative) is handed to
//  a chunker that writes the body document into the chunk index in
//  `SearchChunker.chunkCharacters` chunks, a few chunks per transaction. The
//  names of its attachments are indexed as its attachment-name document.
//
//  Memory is bounded by the slice, one line (long lines are processed in
//  pieces), one chunk and the chunks of one write — never by the message.
//  There is no size test anywhere on this path. `Result.peakBufferedBytes`
//  reports the high-water mark so a test can hold it to that bound.
//
//  The body document is `partial` (not evaluable — "may match") from the
//  moment the message is stored until the stream finishes; then `complete`,
//  `noText`, or `failed` when the original file cannot be read. An
//  interrupted run leaves it `partial` and the next run starts it again.
//

import Foundation
import SQLite3

/// A message's bytes, one slice at a time; nil at the end.
protocol MessageSliceSource {
    mutating func next() throws -> Data?
    /// R5b: where the first byte of the stream sits in the original file, so
    /// the attachment ranges the reader records are absolute (0 for a stream
    /// that is not read from a file).
    var baseOffset: Int64 { get }
}

extension MessageSliceSource {
    var baseOffset: Int64 { 0 }
}

/// The bytes of a located message in its original file, from its header block
/// (after any mbox `From_` line) to its end, in bounded slices.
final class LocatorSliceSource: MessageSliceSource {
    private let path: String
    private let range: ByteRange
    private var remaining: Int64
    private let sliceBytes: Int
    private var handle: FileHandle?

    init(locator: MessageLocator, sliceBytes: Int = 1 << 20) throws {
        path = locator.sourcePath
        let start = locator.headerRange.offset
        range = ByteRange(offset: start, length: max(0, locator.messageRange.end - start))
        remaining = range.length
        self.sliceBytes = max(4_096, sliceBytes)
        guard FileManager.default.fileExists(atPath: path) else { throw LocatorReadError.sourceMissing(path) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        guard range.offset >= 0, range.end <= size else { throw LocatorReadError.rangeUnresolvable(range, fileSize: size) }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw LocatorReadError.ioError("cannot open \(path)") }
        do { try handle.seek(toOffset: UInt64(range.offset)) } catch {
            try? handle.close()
            throw LocatorReadError.ioError(error.localizedDescription)
        }
        self.handle = handle
    }

    deinit { try? handle?.close() }

    var baseOffset: Int64 { range.offset }

    func next() throws -> Data? {
        guard remaining > 0, let handle else {
            try? handle?.close(); handle = nil
            return nil
        }
        let want = Int(min(Int64(sliceBytes), remaining))
        let slice: Data?
        do { slice = try autoreleasepool { try handle.read(upToCount: want) } } catch {
            throw LocatorReadError.ioError(error.localizedDescription)
        }
        guard let slice, !slice.isEmpty else {
            // The file shrank since import: a short read is damage, not the end.
            throw LocatorReadError.rangeUnresolvable(range, fileSize: range.end - remaining)
        }
        remaining -= Int64(slice.count)
        return slice
    }
}

// MARK: - The MIME stream

/// Walks a message's bytes as they arrive and returns the text of its text
/// parts. Holds one line, one part's header block and a few carry bytes.
struct StreamingMIMETextReader {
    /// A line longer than this is processed in pieces (it cannot be a MIME
    /// boundary or a header that matters; base64 and text are line-agnostic).
    static let lineSliceBytes = 64 * 1024
    /// A part's header block is kept up to this size; the fields that matter
    /// (Content-Type, -Transfer-Encoding, -Disposition) come first in practice
    /// and the message's own headers are indexed from the store. Bounded
    /// memory, not a cut of searchable text.
    static let headerBlockBytes = 256 * 1024

    private struct Frame {
        let marker: String          // "--boundary"
        let isAlternative: Bool
        var emittedPlain = false
    }

    private enum Phase { case headers, text, skip }

    private var phase: Phase = .headers
    private var frames: [Frame] = []
    private var line = Data()
    private var continuingLongLine = false
    private var headerLines: [String] = []
    private var headerBytes = 0
    private var decoder: TextPartDecoder?
    private var emittedAny = false
    /// Names of the attachments met on the way (not read here).
    private(set) var attachmentNames: [String] = []
    /// R5b: every attachment part met on the way, with the absolute byte range
    /// of its still-encoded content in the original file, so the attachment
    /// job can stream it out and read it like any other attachment.
    private(set) var attachmentParts: [StreamedAttachmentPart] = []

    // R5b: positions, relative to the start of the stream.
    private let baseOffset: Int64
    private var fed: Int64 = 0
    private var lineStart: Int64 = 0
    private var lineEnd: Int64 = 0
    /// The terminator of the last complete line (2 for CRLF, 1 for LF, 0 after a piece of a long line).
    private var lastTerminator: Int64 = 0
    private var partHeaderStart: Int64 = 0
    private var openPart: StreamedAttachmentPart?
    private var openPartBase64 = false
    private var openPartBase64Characters: Int64 = 0

    /// Bytes held between calls — the line in progress, the header block, the decoder's carry.
    var bufferedBytes: Int { line.count + headerBytes + (decoder?.bufferedBytes ?? 0) }

    init(baseOffset: Int64 = 0) { self.baseOffset = baseOffset }

    /// The text the slice completed. Text parts are separated by a newline.
    mutating func feed(_ data: Data) -> String {
        var out = ""
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if let newline = data[cursor...].firstIndex(of: 0x0A) {
                line.append(data[cursor..<newline])
                cursor = data.index(after: newline)
                lineEnd = fed + Int64(data.distance(from: data.startIndex, to: cursor))
                process(complete: true, into: &out)
            } else {
                line.append(data[cursor...])
                cursor = data.endIndex
                if line.count >= Self.lineSliceBytes {
                    lineEnd = lineStart + Int64(line.count)
                    process(complete: false, into: &out)
                }
            }
        }
        fed += Int64(data.count)
        return out
    }

    /// The text still held at the end of the message.
    mutating func finish() -> String {
        var out = ""
        if !line.isEmpty {
            lineEnd = lineStart + Int64(line.count)
            process(complete: true, into: &out)
        }
        endPart(into: &out)
        closeAttachment(at: fed)
        return out
    }

    private mutating func process(complete: Bool, into out: inout String) {
        let hadCR = complete && line.last == 0x0D
        let thisLineStart = lineStart
        let previousTerminator = lastTerminator
        defer {
            line.removeAll(keepingCapacity: true); continuingLongLine = !complete
            lineStart = lineEnd
            lastTerminator = complete ? (hadCR ? 2 : 1) : 0
        }
        var bytes = line
        if complete, bytes.last == 0x0D { bytes.removeLast() }
        // A boundary line starts a line, is short and starts with "--".
        if !continuingLongLine, !frames.isEmpty, bytes.count >= 2, bytes.count < 1_024,
           bytes[bytes.startIndex] == 0x2D, bytes[bytes.startIndex + 1] == 0x2D {
            let candidate = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            for index in frames.indices.reversed() {
                if candidate == frames[index].marker {
                    endPart(into: &out)
                    // The line break before a boundary belongs to the boundary (RFC 2046 §5.1.1).
                    closeAttachment(at: thisLineStart - previousTerminator)
                    frames.removeSubrange((index + 1)...)
                    startHeaders()
                    partHeaderStart = lineEnd
                    return
                }
                if candidate == frames[index].marker + "--" {
                    endPart(into: &out)
                    closeAttachment(at: thisLineStart - previousTerminator)
                    frames.removeSubrange(index...)
                    phase = .skip     // the epilogue, up to an outer boundary
                    return
                }
            }
        }
        switch phase {
        case .headers:
            if complete, !continuingLongLine, bytes.isEmpty {
                beginPart(into: &out)
                return
            }
            guard headerBytes < Self.headerBlockBytes else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            headerBytes += bytes.count
            if continuingLongLine || (text.first.map { $0 == " " || $0 == "\t" } ?? false), let last = headerLines.popLast() {
                headerLines.append(last + (continuingLongLine ? "" : " ") + text.trimmingCharacters(in: .whitespaces))
            } else {
                headerLines.append(text)
            }
        case .text:
            decoder?.line(bytes, complete: complete, into: &out)
        case .skip:
            // R5b: the decoded size of a base64 attachment, counted on the way past.
            if openPart != nil, openPartBase64 {
                for byte in bytes where TextPartDecoder.isBase64Data(byte) { openPartBase64Characters += 1 }
            }
        }
    }

    /// R5b: the attachment part in progress ends at `end` (relative to the stream).
    private mutating func closeAttachment(at end: Int64) {
        guard var part = openPart else { return }
        openPart = nil
        let start = part.locator.contentRange.offset - baseOffset
        let length = max(0, end - start)
        part.locator.contentRange = ByteRange(offset: baseOffset + start, length: length)
        part.decodedBytes = openPartBase64 ? openPartBase64Characters * 3 / 4 : length
        attachmentParts.append(part)
    }

    private mutating func startHeaders() {
        phase = .headers
        headerLines.removeAll(keepingCapacity: true)
        headerBytes = 0
    }

    private mutating func endPart(into out: inout String) {
        guard var current = decoder else { return }
        current.finish(into: &out)
        if current.producedText, !current.isHTML, !frames.isEmpty, frames[frames.count - 1].isAlternative {
            frames[frames.count - 1].emittedPlain = true
        }
        decoder = nil
    }

    private mutating func beginPart(into out: inout String) {
        closeAttachment(at: lineStart)   // never open: a part always ends at a boundary first
        var fields: [String: String] = [:]
        for header in headerLines {
            guard let colon = header.firstIndex(of: ":") else { continue }
            let name = header[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if fields[name] == nil { fields[name] = String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        headerLines.removeAll(keepingCapacity: true)
        headerBytes = 0

        let contentType = fields["content-type"] ?? ""
        let media = contentType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let typeParameters = Self.parameters(contentType)
        let disposition = fields["content-disposition"] ?? ""
        let dispositionParameters = Self.parameters(disposition)
        let filename = dispositionParameters["filename"] ?? typeParameters["name"]
        let isAttachment = disposition.lowercased().hasPrefix("attachment") || (filename.map { !$0.isEmpty } ?? false)
        let encoding = (fields["content-transfer-encoding"] ?? "").lowercased()

        if media.hasPrefix("multipart/") {
            if let boundary = typeParameters["boundary"], !boundary.isEmpty {
                frames.append(Frame(marker: "--" + boundary, isAlternative: media == "multipart/alternative"))
            }
            phase = .skip          // the preamble, up to the first boundary
            return
        }
        if media == "message/rfc822", !isAttachment, ["", "7bit", "8bit", "binary"].contains(encoding) {
            startHeaders()        // an inline message: its own headers follow
            return
        }
        let isText = media.isEmpty || media == "text/plain" || media == "text/html"
        if isText, !isAttachment {
            let html = media == "text/html"
            if html, let innermost = frames.last, innermost.isAlternative, innermost.emittedPlain {
                phase = .skip      // the plain alternative was read; the HTML would repeat it
                return
            }
            if emittedAny { out += "\n" }
            emittedAny = true
            decoder = TextPartDecoder(transferEncoding: encoding, charset: typeParameters["charset"], html: html)
            phase = .text
            return
        }
        if let filename, !filename.isEmpty { attachmentNames.append(filename) }
        // R5b: the part's still-encoded content starts on the next line.
        if !media.hasPrefix("multipart/") {
            let ordinal = attachmentParts.count
            let named = (filename?.isEmpty == false) ? filename! : "attachment-\(ordinal + 1)"
            let contentID = fields["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
            let locator = PartLocator(messageID: UUID(), path: [ordinal], mimeType: media.isEmpty ? "application/octet-stream" : media,
                                      filename: named, contentID: contentID, contentTransferEncoding: encoding.isEmpty ? nil : encoding,
                                      contentRange: ByteRange(offset: baseOffset + lineEnd, length: 0),
                                      headerRange: ByteRange(offset: baseOffset + partHeaderStart, length: max(0, lineEnd - partHeaderStart)))
            openPart = StreamedAttachmentPart(locator: locator, decodedBytes: 0,
                                              isInline: disposition.lowercased().hasPrefix("inline") || (contentID != nil && filename == nil))
            openPartBase64 = encoding == "base64"
            openPartBase64Characters = 0
        }
        phase = .skip
    }

    /// `type/sub; a=b; c="d e"` → [a: b, c: "d e"] (names lower-cased).
    static func parameters(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in value.split(separator: ";").dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            if out[name] == nil { out[name] = raw }
        }
        return out
    }
}

/// One text part's transfer decoding, charset decoding and (for HTML) tag stripping, line by line.
struct TextPartDecoder {
    private enum Transfer { case identity, base64, quotedPrintable }
    private let transfer: Transfer
    private let encoding: String.Encoding
    let isHTML: Bool
    private var base64Carry: [UInt8] = []
    private var byteCarry = Data()
    private var inTag = false
    private(set) var producedText = false

    var bufferedBytes: Int { base64Carry.count + byteCarry.count }

    init(transferEncoding: String, charset: String?, html: Bool) {
        switch transferEncoding {
        case "base64": transfer = .base64
        case "quoted-printable": transfer = .quotedPrintable
        default: transfer = .identity
        }
        isHTML = html
        encoding = Self.encoding(charset)
    }

    static func encoding(_ charset: String?) -> String.Encoding {
        guard let charset = charset?.trimmingCharacters(in: .whitespaces).lowercased(), !charset.isEmpty,
              charset != "utf-8", charset != "utf8", charset != "us-ascii" else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    mutating func line(_ bytes: Data, complete: Bool, into out: inout String) {
        switch transfer {
        case .identity:
            var decoded = bytes
            if complete { decoded.append(0x0A) }
            emit(decoded, into: &out)
        case .quotedPrintable:
            emit(Self.quotedPrintable(bytes, complete: complete), into: &out)
        case .base64:
            for byte in bytes where Self.isBase64(byte) { base64Carry.append(byte) }
            let whole = base64Carry.count - base64Carry.count % 4
            guard whole > 0 else { return }
            let decoded = Self.base64(Array(base64Carry[0..<whole]))
            base64Carry.removeFirst(whole)
            emit(decoded, into: &out)
        }
    }

    mutating func finish(into out: inout String) {
        if transfer == .base64, !base64Carry.isEmpty {
            // A final group without its padding: decode what it holds.
            var tail = base64Carry
            while tail.count % 4 != 0 { tail.append(0x3D) }
            base64Carry.removeAll()
            emit(Self.base64(tail), into: &out)
        }
        if !byteCarry.isEmpty {
            let rest = byteCarry
            byteCarry.removeAll()
            append(decodeCharset(rest), into: &out)
        }
    }

    private mutating func emit(_ decoded: Data, into out: inout String) {
        guard !decoded.isEmpty else { return }
        byteCarry.append(decoded)
        let cut: Int
        if encoding == .utf8 {
            cut = byteCarry.count - Self.incompleteUTF8Tail(byteCarry)
        } else if let newline = byteCarry.lastIndex(of: 0x0A) {
            cut = byteCarry.distance(from: byteCarry.startIndex, to: newline) + 1
        } else {
            cut = byteCarry.count >= StreamingMIMETextReader.lineSliceBytes ? byteCarry.count : 0
        }
        guard cut > 0 else { return }
        let ready = byteCarry.prefix(cut)
        let text = decodeCharset(Data(ready))
        byteCarry = Data(byteCarry.dropFirst(cut))
        append(text, into: &out)
    }

    private func decodeCharset(_ data: Data) -> String {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private mutating func append(_ text: String, into out: inout String) {
        guard !text.isEmpty else { return }
        let piece = isHTML ? stripTags(text) : text
        if !producedText, piece.contains(where: { !$0.isWhitespace }) { producedText = true }
        out += piece
    }

    /// Tags become a space (as `FTSSearchIndex.stripHTMLText` does), the common entities their characters.
    private mutating func stripTags(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.utf8.count)
        for character in html {
            if inTag {
                if character == ">" { inTag = false; out.append(" ") }
            } else if character == "<" {
                inTag = true
            } else {
                out.append(character)
            }
        }
        guard out.contains("&") else { return out }
        return out.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Bytes at the end that start a UTF-8 sequence not yet complete.
    static func incompleteUTF8Tail(_ data: Data) -> Int {
        let count = data.count
        var k = 1
        while k <= min(3, count) {
            let byte = data[data.index(data.startIndex, offsetBy: count - k)]
            if byte & 0xC0 == 0x80 { k += 1; continue }        // continuation byte
            guard byte >= 0xC0 else { return 0 }                // ASCII: complete
            let needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2)
            return needed > k ? k : 0
        }
        return 0
    }

    /// R5b: a base64 data character (padding excluded), for counting decoded size.
    static func isBase64Data(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2B || byte == 0x2F
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2B || byte == 0x2F || byte == 0x3D
    }

    /// Whole groups; a group padded in the middle of a stream (two encodings
    /// concatenated) is decoded group by group.
    private static func base64(_ groups: [UInt8]) -> Data {
        if let whole = Data(base64Encoded: Data(groups)) { return whole }
        var out = Data()
        var index = 0
        while index + 4 <= groups.count {
            if let group = Data(base64Encoded: Data(groups[index..<(index + 4)])) { out.append(group) }
            index += 4
        }
        return out
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// RFC 2045 §6.7: `=XY` is a byte, a trailing `=` joins the next line.
    static func quotedPrintable(_ line: Data, complete: Bool) -> Data {
        var bytes = Array(line)
        while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
        var soft = false
        if complete, bytes.last == 0x3D { bytes.removeLast(); soft = true }
        var out = Data()
        out.reserveCapacity(bytes.count + 1)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D, index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        if complete, !soft { out.append(0x0A) }
        return out
    }
}

/// Text in, contiguous chunks out — the same cut as `SearchChunker.chunks`
/// (at most `chunk` Characters, backed up to a whitespace so a word is never
/// cut in two), produced as the text arrives.
struct StreamingChunker {
    let chunk: Int
    private(set) var pending = ""
    private var pendingCount = 0

    init(chunk: Int = SearchChunker.chunkCharacters) { self.chunk = chunk }

    var bufferedBytes: Int { pending.utf8.count }

    /// Every chunk the text completed; the rest waits for more text or `finish`.
    mutating func append(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        pending += text
        pendingCount += text.count
        guard pendingCount > chunk else { return [] }
        var out: [String] = []
        var start = pending.startIndex
        var left = pendingCount
        while left > chunk {
            guard let hardEnd = pending.index(start, offsetBy: chunk, limitedBy: pending.endIndex) else { break }
            var end = hardEnd
            var probe = hardEnd
            var steps = 0
            while probe > start, steps < 256 {
                probe = pending.index(before: probe)
                if pending[probe].isWhitespace { end = pending.index(after: probe); break }
                steps += 1
            }
            let piece = String(pending[start..<end])
            left -= piece.count
            out.append(piece)
            start = end
        }
        pending = String(pending[start...])
        pendingCount = pending.count
        return out
    }

    mutating func finish() -> String? {
        defer { pending = ""; pendingCount = 0 }
        return pending.isEmpty ? nil : pending
    }
}

// MARK: - The indexer

struct StreamedBodyIndexer: Sendable {
    /// Stamped as the body document's `extractor_version`.
    /// 2 (R5b, 2026-11-09): the attachment parts met on the way are registered
    /// by byte range so their contents are read too — version-1 bodies are
    /// streamed again once to register them.
    static let version = 2

    /// Chunks per write transaction (about 400K characters).
    var chunksPerWrite = 8

    struct Result: Sendable, Equatable {
        var chunks = 0
        var characters = 0
        var bytesRead: Int64 = 0
        /// High-water mark of everything held at once: the slice, the reader's
        /// line/header/carry, the text of one slice, the chunker and the chunks
        /// awaiting their write.
        var peakBufferedBytes = 0
        var attachmentNames: [String] = []
        /// R5b: the attachment parts, by absolute byte range in the original file.
        var attachmentParts: [StreamedAttachmentPart] = []
        var state: SearchDocState = .partial
    }

    init(chunksPerWrite: Int = 8) { self.chunksPerWrite = max(1, chunksPerWrite) }

    /// Streams one message's text into its body document.
    func index<Source: MessageSliceSource>(emailID: UUID, source: inout Source, store: SQLiteEmailStore) async throws -> Result {
        var result = Result()
        var reader = StreamingMIMETextReader(baseOffset: source.baseOffset)
        var chunker = StreamingChunker()
        var waiting: [String] = []
        var waitingBytes = 0
        var sawText = false
        try await store.beginStreamedBody(emailID: emailID)

        func take(_ chunks: [String]) {
            for chunk in chunks {
                if !sawText, chunk.contains(where: { !$0.isWhitespace }) { sawText = true }
                waiting.append(chunk)
                waitingBytes += chunk.utf8.count
            }
        }
        func flush() async throws {
            guard !waiting.isEmpty else { return }
            try await store.appendStreamedBodyChunks(emailID: emailID, firstIndex: result.chunks, chunks: waiting)
            result.chunks += waiting.count
            result.characters += waiting.reduce(0) { $0 + $1.count }
            waiting.removeAll(keepingCapacity: true)
            waitingBytes = 0
        }

        while let slice = try source.next() {
            try Task.checkCancellation()
            result.bytesRead += Int64(slice.count)
            let text = reader.feed(slice)
            let held = slice.count + reader.bufferedBytes + text.utf8.count + chunker.bufferedBytes + waitingBytes
            result.peakBufferedBytes = max(result.peakBufferedBytes, held)
            take(chunker.append(text))
            if waiting.count >= chunksPerWrite { try await flush() }
        }
        take(chunker.append(reader.finish()))
        if let last = chunker.finish() { take([last]) }
        try await flush()
        result.attachmentNames = reader.attachmentNames
        result.attachmentParts = reader.attachmentParts.map { part in
            var part = part
            part.locator.messageID = emailID
            return part
        }
        result.state = sawText ? .complete : .noText
        try await store.finishStreamedBody(emailID: emailID, chunkCount: result.chunks, characters: result.characters,
                                           state: result.state, attachmentNames: result.attachmentNames,
                                           attachmentParts: result.attachmentParts)
        return result
    }

    struct PassOutcome: Sendable, Equatable {
        var indexed = 0
        var failed = 0
    }

    /// Every stored message whose body waits to be streamed, a page at a time.
    /// A message whose original file cannot be read is recorded `failed` (its
    /// body is then reported not evaluable, never "no match").
    func indexPending(store: SQLiteEmailStore, sliceBytes: Int = 1 << 20,
                      progress: (@Sendable (PassOutcome) async -> Void)? = nil) async -> PassOutcome {
        var outcome = PassOutcome()
        var attempted = Set<UUID>()
        while !Task.isCancelled {
            guard let ids = try? await store.streamedBodyWorkList(limit: 20) else { break }
            let fresh = ids.filter { !attempted.contains($0) }
            if fresh.isEmpty { break }
            for id in fresh {
                if Task.isCancelled { break }
                attempted.insert(id)
                do {
                    guard let locator = try await store.locator(forEmailID: id) else {
                        throw LocatorReadError.sourceMissing("(no locator)")
                    }
                    var source = try LocatorSliceSource(locator: locator, sliceBytes: sliceBytes)
                    _ = try await index(emailID: id, source: &source, store: store)
                    outcome.indexed += 1
                } catch is CancellationError {
                    return outcome         // left partial: the next run starts it again
                } catch {
                    outcome.failed += 1
                    try? await store.finishStreamedBody(emailID: id, chunkCount: 0, characters: 0, state: .failed, attachmentNames: [])
                }
                await progress?(outcome)
            }
        }
        return outcome
    }
}

// MARK: - The store side

extension SQLiteEmailStore {

    /// Messages stored from their headers whose body document waits to be streamed.
    func streamedBodyWorkList(limit: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT l.email_id FROM message_locators l
            WHERE l.body_decoded = 0
              AND EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = l.email_id AND d.kind = 'body'
                          AND (d.state = 'partial' OR d.extractor_version < ?))
            ORDER BY l.ordinal LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(StreamedBodyIndexer.version))
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    /// True when the message was stored from its headers only (its body is in the original file).
    func isDeferredBody(_ db: OpaquePointer, emailID: String) throws -> Bool {
        let stmt = try prepare(db, "SELECT 1 FROM message_locators WHERE email_id = ? AND body_decoded = 0;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID)
        return try stepRow(stmt, db)
    }

    /// Clears the body's chunks and marks it `partial` while the stream runs.
    func beginStreamedBody(emailID: UUID) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try indexSearchDocument(db, emailID: emailID.uuidString, kind: .body, ordinal: 0, text: nil, state: .partial,
                                    extractorVersion: StreamedBodyIndexer.version)
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Appends chunks `firstIndex…` of the body, in one transaction.
    func appendStreamedBodyChunks(emailID: UUID, firstIndex: Int, chunks: [String]) throws {
        guard !chunks.isEmpty else { return }
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let insert = try prepare(db, "INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text) VALUES (?,'body',0,?,?);")
            defer { sqlite3_finalize(insert) }
            for (offset, chunk) in chunks.enumerated() {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, emailID.uuidString)
                sqlite3_bind_int64(insert, 2, Int64(firstIndex + offset))
                bindText(insert, 3, chunk)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Records the finished body document (and the attachment names met on the way).
    /// R5b: a finished stream (not `failed`) also registers the attachment parts
    /// it met — byte ranges, the message's attachment list — and puts the
    /// message on the attachment job's work list so their contents are read.
    func finishStreamedBody(emailID: UUID, chunkCount: Int, characters: Int, state: SearchDocState, attachmentNames: [String],
                            attachmentParts: [StreamedAttachmentPart] = []) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let id = emailID.uuidString
            let update = try prepare(db, """
                INSERT INTO search_docs(email_id, kind, ordinal, revision, chunk_count, text_chars, state, extractor_version, ocr)
                VALUES (?,'body',0,1,?,?,?,?,0)
                ON CONFLICT(email_id, kind, ordinal) DO UPDATE SET
                    revision = search_docs.revision + 1, chunk_count = excluded.chunk_count, text_chars = excluded.text_chars,
                    state = excluded.state, extractor_version = excluded.extractor_version;
            """)
            defer { sqlite3_finalize(update) }
            bindText(update, 1, id)
            sqlite3_bind_int64(update, 2, Int64(chunkCount)); sqlite3_bind_int64(update, 3, Int64(characters))
            bindText(update, 4, state.rawValue); sqlite3_bind_int64(update, 5, Int64(StreamedBodyIndexer.version))
            guard sqlite3_step(update) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            if !attachmentNames.isEmpty {
                try indexSearchDocument(db, emailID: id, kind: .attachmentName, ordinal: 0,
                                        text: attachmentNames.joined(separator: "\n"), state: .complete)
            }
            if state != .failed {
                try registerStreamedAttachments(db, emailID: emailID, parts: attachmentParts)
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// The state of one message's body document (nil when it has none).
    func bodyDocumentState(emailID: UUID) throws -> SearchDocState? {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT state FROM search_docs WHERE email_id = ? AND kind = 'body' AND ordinal = 0;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString)
        guard try stepRow(stmt, db) else { return nil }
        return SearchDocState(rawValue: columnText(stmt, 0))
    }
}
