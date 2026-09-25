//
//  MIMEPartScanner.swift
//  maxmailin
//
//  S5 completion: where each MIME part LIVES, as absolute byte ranges, so an
//  attachment can be read without materialising its siblings.
//
//  Why a second MIME walker exists alongside `MIMEParser`/`MIMEPart`: that one
//  is String-based and builds `body`/`rawBody` for every part, which is the
//  cost this avoids. Opening a 10 KB attachment inside a 12 MB message used to
//  materialise all 12 MB as a Swift String and parse the whole tree. This
//  produces only ranges — nothing is decoded and nothing is copied except each
//  part's own bounded header block.
//
//  Boundary rules implemented (RFC 2046 §5.1):
//   • a delimiter is `--boundary` at the START of a line, never mid-line;
//   • `--boundary--` closes the multipart and ends the last part;
//   • the CRLF (or LF) that PRECEDES a delimiter belongs to the delimiter, not
//     to the part before it — including it would corrupt every extracted
//     attachment by two bytes;
//   • a part's own header block ends at the first blank line; a part may have
//     no headers at all, in which case its content starts immediately.
//
//  Depth is bounded because a crafted message can nest multipart forever. The
//  limit is format-driven, not a convenience cap: real mail nests 2–3 deep.
//

import Foundation

struct MIMEPartScanner {

    /// A part's own header block cannot reasonably exceed this. A message that
    /// claims otherwise is malformed, and the part is emitted with whatever
    /// headers were found rather than dropped.
    static let maxPartHeaderBytes = 64 * 1024

    /// Nesting limit. multipart/mixed → multipart/alternative → text is depth 2
    /// in real mail; 16 leaves room for anything legitimate while refusing an
    /// unbounded recursion.
    static let maxDepth = 16

    /// Walks the MIME structure of one message.
    ///
    /// - Parameters:
    ///   - bodyData: the message's body bytes — everything after its header
    ///     block's blank line.
    ///   - bodyOffset: where `bodyData` starts in the SOURCE FILE, so every
    ///     range returned is absolute and independently readable.
    ///   - topHeaders: the message's own headers, for its Content-Type.
    ///   - messageID: the owning message.
    /// - Returns: one `PartLocator` per leaf part, in document order. A
    ///   non-multipart message yields exactly one.
    static func parts(bodyData: Data,
                      bodyOffset: Int64,
                      topHeaders: [String: String],
                      messageID: UUID) -> [PartLocator] {
        var out: [PartLocator] = []
        walk(data: bodyData,
             range: bodyData.startIndex..<bodyData.endIndex,
             baseOffset: bodyOffset,
             headers: topHeaders,
             path: [],
             depth: 0,
             messageID: messageID,
             into: &out)
        return out
    }

    // MARK: - Walk

    private static func walk(data: Data,
                             range: Range<Data.Index>,
                             baseOffset: Int64,
                             headers: [String: String],
                             path: [Int],
                             depth: Int,
                             messageID: UUID,
                             into out: inout [PartLocator]) {
        let contentType = headers["Content-Type"] ?? headers["content-type"] ?? ""
        let isMultipart = contentType.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .hasPrefix("multipart/")
        let boundary = MIMEPart.extractParameter("boundary", from: contentType)

        // A multipart with no boundary is malformed: treat it as a leaf so its
        // bytes stay reachable rather than being silently dropped.
        guard isMultipart, let boundary, !boundary.isEmpty, depth < maxDepth else {
            out.append(leaf(range: range,
                            baseOffset: baseOffset,
                            headerRange: nil,
                            headers: headers,
                            path: path.isEmpty ? [0] : path,
                            messageID: messageID))
            return
        }

        let delimiters = delimiterLines(in: data, range: range, boundary: boundary)
        guard !delimiters.isEmpty else {
            // Declared multipart, no delimiter actually present.
            out.append(leaf(range: range,
                            baseOffset: baseOffset,
                            headerRange: nil,
                            headers: headers,
                            path: path.isEmpty ? [0] : path,
                            messageID: messageID))
            return
        }

        // Each part spans from the end of one delimiter line to the start of
        // the next delimiter (excluding the newline that precedes it).
        for (index, delimiter) in delimiters.enumerated() {
            if delimiter.isClosing { break }
            let contentStart = delimiter.lineEnd
            guard index + 1 < delimiters.count else { break }
            let next = delimiters[index + 1]
            let contentEnd = max(contentStart, next.precedingNewlineStart)
            guard contentStart < contentEnd else { continue }

            let partRange = contentStart..<contentEnd
            let (partHeaders, headerEnd) = parseHeaderBlock(in: data, range: partRange)
            let childPath = path + [index]

            let childType = (partHeaders["Content-Type"] ?? "").lowercased()
            if childType.trimmingCharacters(in: .whitespaces).hasPrefix("multipart/") {
                walk(data: data,
                     range: headerEnd..<contentEnd,
                     baseOffset: baseOffset,
                     headers: partHeaders,
                     path: childPath,
                     depth: depth + 1,
                     messageID: messageID,
                     into: &out)
            } else {
                out.append(leaf(range: headerEnd..<contentEnd,
                                baseOffset: baseOffset,
                                headerRange: partRange.lowerBound..<headerEnd,
                                headers: partHeaders,
                                path: childPath,
                                messageID: messageID))
            }
        }
    }

    private static func leaf(range: Range<Data.Index>,
                             baseOffset: Int64,
                             headerRange: Range<Data.Index>?,
                             headers: [String: String],
                             path: [Int],
                             messageID: UUID) -> PartLocator {
        let contentType = headers["Content-Type"] ?? headers["content-type"] ?? "text/plain"
        let mimeType = contentType
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? "text/plain"

        let disposition = headers["Content-Disposition"] ?? ""
        let filename = MIMEPart.extractParameter("filename", from: disposition)
            ?? MIMEPart.extractParameter("name", from: contentType)

        let contentID = (headers["Content-ID"] ?? headers["Content-Id"])?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))

        return PartLocator(
            messageID: messageID,
            path: path,
            mimeType: mimeType,
            filename: filename?.isEmpty == true ? nil : filename,
            contentID: contentID?.isEmpty == true ? nil : contentID,
            contentTransferEncoding: headers["Content-Transfer-Encoding"]?
                .trimmingCharacters(in: .whitespaces).lowercased(),
            contentRange: absolute(range, baseOffset),
            headerRange: absolute(headerRange ?? range.lowerBound..<range.lowerBound, baseOffset))
    }

    private static func absolute(_ range: Range<Data.Index>, _ baseOffset: Int64) -> ByteRange {
        ByteRange(offset: baseOffset + Int64(range.lowerBound),
                  length: Int64(range.count))
    }

    // MARK: - Delimiters

    private struct Delimiter {
        /// First byte of the `--boundary` text.
        let start: Data.Index
        /// First byte AFTER the delimiter line's newline.
        let lineEnd: Data.Index
        /// Where the newline that precedes this delimiter begins. That newline
        /// belongs to the delimiter, so the preceding part ends here.
        let precedingNewlineStart: Data.Index
        let isClosing: Bool
    }

    private static func delimiterLines(in data: Data,
                                       range: Range<Data.Index>,
                                       boundary: String) -> [Delimiter] {
        let marker = Data(("--" + boundary).utf8)
        guard !marker.isEmpty else { return [] }

        var result: [Delimiter] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let lineEnd = endOfLine(in: data, from: index, limit: range.upperBound)
            let lineLength = lineEnd.contentEnd - index
            if lineLength >= marker.count,
               data[index..<(index + marker.count)] == marker {
                // `--boundary--` closes; `--boundary` opens the next part.
                let afterMarker = index + marker.count
                var isClosing = false
                if afterMarker + 1 < lineEnd.contentEnd,
                   data[afterMarker] == 0x2D, data[afterMarker + 1] == 0x2D {
                    isClosing = true
                } else if afterMarker + 1 == lineEnd.contentEnd,
                          data[afterMarker] == 0x2D {
                    // A single trailing dash is malformed; not a close.
                    isClosing = false
                }
                // Trailing whitespace after the boundary is permitted.
                let tail = data[afterMarker..<lineEnd.contentEnd]
                let tailIsBlank = tail.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x2D }
                if tailIsBlank {
                    result.append(Delimiter(
                        start: index,
                        lineEnd: lineEnd.next,
                        precedingNewlineStart: newlineStart(before: index, in: data, floor: range.lowerBound),
                        isClosing: isClosing))
                }
            }
            if lineEnd.next <= index { break }   // no forward progress: stop
            index = lineEnd.next
        }
        return result
    }

    /// The newline immediately before `index`, treated as part of the
    /// delimiter. Handles both CRLF and bare LF; returns `index` when there is
    /// none (the delimiter is the very first thing in the body).
    private static func newlineStart(before index: Data.Index,
                                     in data: Data,
                                     floor: Data.Index) -> Data.Index {
        guard index > floor, data[index - 1] == 0x0A else { return index }
        if index - 1 > floor, data[index - 2] == 0x0D { return index - 2 }
        return index - 1
    }

    private struct LineEnd {
        /// End of the line's content, excluding its newline.
        let contentEnd: Data.Index
        /// Start of the next line.
        let next: Data.Index
    }

    private static func endOfLine(in data: Data,
                                  from index: Data.Index,
                                  limit: Data.Index) -> LineEnd {
        var cursor = index
        while cursor < limit, data[cursor] != 0x0A { cursor += 1 }
        guard cursor < limit else { return LineEnd(contentEnd: limit, next: limit) }
        var contentEnd = cursor
        if contentEnd > index, data[contentEnd - 1] == 0x0D { contentEnd -= 1 }
        return LineEnd(contentEnd: contentEnd, next: cursor + 1)
    }

    // MARK: - Part headers

    /// Parses a part's own header block. Returns the headers and the index
    /// where content begins (after the blank line). A part with no blank line
    /// is all headers and no content, which the caller sees as a zero-length
    /// content range rather than as a guess.
    private static func parseHeaderBlock(in data: Data,
                                         range: Range<Data.Index>)
        -> ([String: String], Data.Index) {
        var headers: [String: String] = [:]
        var index = range.lowerBound
        var lastKey: String?
        let budget = min(range.upperBound, range.lowerBound + maxPartHeaderBytes)

        while index < budget {
            let line = endOfLine(in: data, from: index, limit: range.upperBound)
            if line.contentEnd == index {
                // Blank line: header block ends, content starts next.
                return (headers, min(line.next, range.upperBound))
            }
            let bytes = data[index..<line.contentEnd]
            if let first = bytes.first, first == 0x20 || first == 0x09, let key = lastKey {
                // Folded continuation (RFC 5322 §2.2.3).
                let continuation = String(decoding: bytes).trimmingCharacters(in: .whitespaces)
                headers[key] = (headers[key] ?? "") + " " + continuation
            } else if let colon = bytes.firstIndex(of: 0x3A) {
                let key = String(decoding: data[bytes.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(decoding: data[(colon + 1)..<line.contentEnd])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    headers[key] = value
                    lastKey = key
                }
            } else if headers.isEmpty {
                // First line is not a header at all: this part has no header
                // block, so content starts where we began.
                return ([:], range.lowerBound)
            }
            if line.next <= index { break }
            index = line.next
        }
        // Ran out of budget or data without a blank line.
        return (headers, min(index, range.upperBound))
    }
}

private extension String {
    /// Part headers are ASCII by spec; latin-1 is the lenient fallback so a
    /// malformed byte cannot drop a whole header.
    init(decoding bytes: Data.SubSequence) {
        self = String(data: Data(bytes), encoding: .utf8)
            ?? String(data: Data(bytes), encoding: .isoLatin1)
            ?? ""
    }
}
