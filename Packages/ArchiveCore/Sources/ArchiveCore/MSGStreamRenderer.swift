//
//  MSGStreamRenderer.swift
//  ArchiveCore
//
//  CLOSE-01 (v4 plan §8.1): an Outlook .msg file of any size, rendered as RFC
//  5322 in bounded memory.
//
//  A .msg has no RFC 5322 bytes of its own; the archive keeps a rendered
//  source for it (`RenderedSource.swift`), built in memory with every
//  attachment base64-encoded into one string. For a file above the offset
//  engine's full-parse ceiling that string would be larger than the file, so
//  this renderer writes the same structure to a file instead: the same header
//  block (`RFC822Renderer.headerBlock`), the same text / HTML alternatives and
//  attachment parts, every large property stream (body, HTML, attachment data)
//  read through `OLE2Reader.streamEntry` in slices and base64-encoded as it
//  passes. Memory is bounded by one slice plus the output buffer, never by a
//  body or an attachment. Embedded messages are rendered in place, at every
//  level, as base64 `message/rfc822` parts (as the in-memory reader does); a
//  storage inside itself is listed as the attachment it is.
//
//  The rendered file is then imported by the offset engine like any large
//  .eml: headers plus a byte locator, its text streamed into the search index
//  and its attachments streamed out of their byte ranges after import.
//

import CryptoKit
import Foundation

/// Where rendered bytes go.
protocol RenderSink: AnyObject {
    func write(_ data: Data) throws
}

extension RenderSink {
    func write(_ text: String) throws { try write(Data(text.utf8)) }
}

/// Buffered output: bytes reach `sink` in slices, counted and hashed on the way.
final class RenderedMessageSink: RenderSink {
    private let sink: (Data) throws -> Void
    private var buffer = Data()
    private let flushBytes: Int
    private var hasher = SHA256()
    private(set) var bytesWritten: Int64 = 0
    /// High-water mark of the output buffer.
    private(set) var peakBufferedBytes = 0

    init(flushBytes: Int = 1 << 20, sink: @escaping (Data) throws -> Void) {
        self.flushBytes = max(4_096, flushBytes)
        self.sink = sink
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        buffer.append(data)
        peakBufferedBytes = max(peakBufferedBytes, buffer.count)
        if buffer.count >= flushBytes { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        hasher.update(data: buffer)
        bytesWritten += Int64(buffer.count)
        try sink(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Flushes and returns the SHA-256 of everything written.
    func finish() throws -> String {
        try flush()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Base64 at 76 columns with CRLF after every line (RFC 2045), streamed:
/// whole 57-byte groups leave as they arrive; at most 56 bytes are carried.
struct StreamingBase64Encoder {
    private var carry = Data()
    private var wroteAnything = false

    mutating func encode(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var input = data
        if !carry.isEmpty {
            input = carry + data
            carry = Data()
        }
        let whole = (input.count / 57) * 57
        if whole < input.count { carry = input.subdata(in: (input.startIndex + whole)..<input.endIndex) }
        guard whole > 0 else { return Data() }
        wroteAnything = true
        let groups = whole == input.count ? input : input.subdata(in: input.startIndex..<(input.startIndex + whole))
        var out = groups.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        out.append(contentsOf: [0x0D, 0x0A])
        return out
    }

    /// The last line (and its CRLF); a lone CRLF when nothing was encoded,
    /// as `RFC822Renderer` writes an empty part.
    mutating func finish() -> Data {
        var out = carry.base64EncodedData()
        carry = Data()
        if !out.isEmpty || !wroteAnything { out.append(contentsOf: [0x0D, 0x0A]) }
        return out
    }
}

/// A sink that base64-encodes into another sink (a nested `message/rfc822` part).
final class Base64RenderSink: RenderSink {
    private let outer: RenderSink
    private var encoder = StreamingBase64Encoder()

    init(into outer: RenderSink) { self.outer = outer }

    func write(_ data: Data) throws { try outer.write(encoder.encode(data)) }
    func finish() throws { try outer.write(encoder.finish()) }
}

/// UTF-16LE to UTF-8, streamed: an odd byte or a high surrogate at the end of
/// a slice waits for the next one.
struct UTF16LETranscoder {
    private var carry = Data()

    mutating func feed(_ data: Data, final: Bool = false) -> Data {
        var input = carry.isEmpty ? data : carry + data
        carry = Data()
        var usable = input.count & ~1
        if !final, usable >= 2 {
            let i = input.startIndex + usable - 2
            let last = UInt16(input[i]) | (UInt16(input[i + 1]) << 8)
            if (0xD800...0xDBFF).contains(last) { usable -= 2 }
        }
        if usable < input.count {
            carry = input.subdata(in: (input.startIndex + usable)..<input.endIndex)
            input = input.subdata(in: input.startIndex..<(input.startIndex + usable))
        }
        var units = [UInt16]()
        units.reserveCapacity(usable / 2)
        var i = input.startIndex
        while i + 1 < input.endIndex {
            units.append(UInt16(input[i]) | (UInt16(input[i + 1]) << 8))
            i += 2
        }
        var out = Data(String(decoding: units, as: UTF16.self).utf8)
        if final, !carry.isEmpty {
            out.append(Data("\u{FFFD}".utf8))
            carry = Data()
        }
        return out
    }
}

enum MSGStreamRenderer {

    /// Property streams larger than this are streamed, never held. A memory
    /// strategy, not a limit: smaller ones are read whole, as before.
    static let inPlaceStreamBytes = 1 << 20

    struct Outcome: Sendable, Equatable {
        var bytesWritten: Int64
        var sha256: String
        var attachmentCount: Int
        /// High-water mark of the output buffer (the slice in hand is at most `sliceBytes`).
        var peakBufferedBytes: Int
    }

    /// Renders `msgURL` into a new file at `output` (replaced if present).
    static func render(msgURL: URL, to output: URL, sliceBytes: Int = 1 << 20) throws -> Outcome {
        let ole = try OLE2Reader(fileURL: msgURL)
        try? FileManager.default.removeItem(at: output)
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: output.path) else {
            throw MSGError.invalidFormat("cannot write \(output.lastPathComponent)")
        }
        do {
            let sink = RenderedMessageSink(flushBytes: sliceBytes) { try handle.write(contentsOf: $0) }
            let count = try render(ole: ole, into: sink, sliceBytes: sliceBytes)
            let digest = try sink.finish()
            try handle.synchronize()
            try handle.close()
            return Outcome(bytesWritten: sink.bytesWritten, sha256: digest, attachmentCount: count, peakBufferedBytes: sink.peakBufferedBytes)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Renders the top-level message of `ole` into `sink`; returns its attachment count.
    @discardableResult
    static func render(ole: OLE2Reader, into sink: RenderSink, sliceBytes: Int = 1 << 20) throws -> Int {
        let properties = try ole.readMAPIProperties(storage: 0, propertiesHeader: 32, deferStreamsAbove: inPlaceStreamBytes)
        return try renderMessage(ole, storage: 0, properties: properties, ancestors: [0],
                                 provenance: "Outlook .msg", into: sink, sliceBytes: sliceBytes)
    }

    private enum Text {
        case string(String)
        case stream(MAPIPropertySet.DeferredStream)
    }

    private static func renderMessage(_ ole: OLE2Reader, storage: Int, properties: MAPIPropertySet, ancestors: Set<Int>,
                                      provenance: String?, into sink: RenderSink, sliceBytes: Int) throws -> Int {
        let parts = MSGParser.messageHeaders(properties)
        try sink.write(RFC822Renderer.headerBlock(headers: parts.headers, timestamp: parts.timestamp, provenance: provenance))

        // The same bodies the in-memory reader renders: plain text and HTML (RTF only feeds its anomaly check).
        let plain: Text? = properties.deferred[MAPIPropertyID.body.rawValue].map(Text.stream)
            ?? properties.stringProperty(.body).flatMap { $0.isEmpty ? nil : Text.string($0) }
        let html: Text? = properties.deferred[MAPIPropertyID.htmlBody.rawValue].map(Text.stream)
            ?? properties.binaryProperty(.htmlBody).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : Text.string($0) }

        func bodyPart() throws {
            if let plain, let html {
                let boundary = "=_mailin_alt_" + UUID().uuidString
                try sink.write("Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n")
                try sink.write("--\(boundary)\r\n")
                try textPart("text/plain", plain)
                try sink.write("--\(boundary)\r\n")
                try textPart("text/html", html)
                try sink.write("--\(boundary)--\r\n")
            } else if let html {
                try textPart("text/html", html)
            } else {
                try textPart("text/plain", plain ?? .string(""))
            }
        }

        func textPart(_ type: String, _ text: Text) throws {
            try sink.write("Content-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n")
            var encoder = StreamingBase64Encoder()
            switch text {
            case .string(let value):
                try sink.write(encoder.encode(Data(value.utf8)))
            case .stream(let deferred):
                var utf16 = UTF16LETranscoder()
                try ole.streamEntry(deferred.entry, sliceBytes: sliceBytes) { slice in
                    switch deferred.propType {
                    case 0x001F: try sink.write(encoder.encode(utf16.feed(slice)))
                    case 0x001E:
                        let decoded = String(data: slice, encoding: .windowsCP1252) ?? String(decoding: slice, as: UTF8.self)
                        try sink.write(encoder.encode(Data(decoded.utf8)))
                    default: try sink.write(encoder.encode(slice))   // HTML: its own bytes
                    }
                }
                if deferred.propType == 0x001F { try sink.write(encoder.encode(utf16.feed(Data(), final: true))) }
            }
            try sink.write(encoder.finish())
        }

        let records = try ole.readAttachments(storage: storage, deferStreamsAbove: inPlaceStreamBytes)
        if records.isEmpty {
            try bodyPart()
            return 0
        }
        let boundary = "=_mailin_mixed_" + UUID().uuidString
        try sink.write("Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n")
        try sink.write("--\(boundary)\r\n")
        try bodyPart()
        for record in records {
            try Task.checkCancellation()
            try sink.write("--\(boundary)\r\n")
            if let embedded = record.embeddedMessageStorage {
                if !ancestors.contains(embedded) {
                    let inner = try ole.readMAPIProperties(storage: embedded, propertiesHeader: 24, deferStreamsAbove: inPlaceStreamBytes)
                    let name = MSGParser.attachedMessageName(subject: inner.stringProperty(.subject) ?? "(No Subject)",
                                                              fallback: record.metadata.filename)
                    try sink.write(partHeader(name: name, mimeType: "message/rfc822", isInline: false, contentID: nil))
                    let nested = Base64RenderSink(into: sink)
                    _ = try renderMessage(ole, storage: embedded, properties: inner, ancestors: ancestors.union([embedded]),
                                          provenance: nil, into: nested, sliceBytes: sliceBytes)
                    try nested.finish()
                } else {
                    // A storage inside itself: kept as the attachment it is, under Outlook's own type, with no bytes.
                    let name = record.metadata.filename == "attachment" ? "embedded-message.msg" : record.metadata.filename
                    try sink.write(partHeader(name: name, mimeType: "application/vnd.ms-outlook", isInline: false, contentID: nil))
                    var encoder = StreamingBase64Encoder()
                    try sink.write(encoder.finish())
                }
                continue
            }
            let metadata = record.metadata
            try sink.write(partHeader(name: metadata.filename, mimeType: metadata.mimeType,
                                      isInline: metadata.isInline, contentID: metadata.contentID))
            var encoder = StreamingBase64Encoder()
            if let deferred = record.deferredData {
                try ole.streamEntry(deferred, sliceBytes: sliceBytes) { try sink.write(encoder.encode($0)) }
            } else if let base64 = metadata.base64, let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                try sink.write(encoder.encode(bytes))
            }
            try sink.write(encoder.finish())
        }
        try sink.write("--\(boundary)--\r\n")
        return records.count
    }

    /// The part header `RFC822Renderer` writes for an attachment.
    private static func partHeader(name rawName: String, mimeType: String, isInline: Bool, contentID: String?) -> String {
        let name = RFC822Renderer.quotedParameter(rawName)
        let mime = mimeType.isEmpty ? "application/octet-stream" : mimeType
        var part = "Content-Type: \(mime); name=\"\(name)\"\r\n"
        part += "Content-Transfer-Encoding: base64\r\n"
        if isInline, let contentID, !contentID.isEmpty {
            part += "Content-ID: <\(contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))>\r\n"
            part += "Content-Disposition: inline; filename=\"\(name)\"\r\n\r\n"
        } else {
            part += "Content-Disposition: attachment; filename=\"\(name)\"\r\n\r\n"
        }
        return part
    }
}
