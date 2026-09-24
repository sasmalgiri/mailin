//
//  OffsetMBOXScanner.swift
//  mailin
//
//  S4: find message boundaries by scanning bytes, parse headers only, never
//  decode a body at import.
//
//  Why this exists. The streaming parser's unit of work is "the message as a
//  Swift String": it accumulates lines until the next `From ` separator, then
//  hands the joined text to the MIME parser. That makes peak memory a function
//  of the LARGEST MESSAGE, which is why `MBOXParser.maxMessageBytes` had to
//  exist — a 150 MB message would otherwise be 150 MB resident plus whatever
//  the MIME tree costs. The ceiling was the honest response to that design,
//  not a format limit, and it means a legitimate large message is reported as
//  damaged and skipped.
//
//  This scanner's unit of work is a RANGE. It reads through the file in a
//  fixed window, records where each message starts and ends, parses only the
//  header block (bounded by `maxHeaderBytes`), and never touches the body.
//  Peak memory is the window plus the headers, whatever the message size.
//
//  Shipped behind `Capability.offsetParser`, OFF by default. The streaming
//  parser is untouched and remains the default path, so turning this on and
//  off is a switch rather than a migration.
//
//  Guard rails that must stay true (SIZE_LIMITS_DESIGN.md §S4), and how:
//   • **I/O error throws, never fake EOF** — a failed `read` throws
//     `ExtractionError.invalidEmail`; only a genuine zero-length read is EOF.
//     Treating an error as end-of-file silently truncates an archive.
//   • **Source-scoped recovery report** — returned, never global, so
//     concurrent imports cannot race (§7.7).
//   • **`From_` quoting is not misread** — a separator must start a line AND
//     carry a 4-digit year, the same test the streaming parser uses, so
//     `>From` inside a body cannot split a message.
//   • **Boundaries are found across window edges** — the window keeps a
//     carry-over tail, so a separator that straddles a read is still found.
//

import Foundation
import os.log

private let scannerLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin",
                                category: "OffsetScanner")

struct OffsetMBOXScanner: Sendable {

    /// Read window. Large enough that syscall overhead is irrelevant, small
    /// enough to be an unremarkable allocation.
    var windowBytes: Int = 1 << 20              // 1 MiB

    /// Headers are parsed, so they ARE resident. RFC 5322 has no limit, but a
    /// header block beyond this is malformed or hostile, and the message is
    /// still indexed — only its header parse is truncated, and that is
    /// reported. This is a bound on the parse, not on the message.
    var maxHeaderBytes: Int = 1 << 20           // 1 MiB

    /// Step size for reading a message's header block. Real mail terminates
    /// its headers well inside one step, so a message normally costs a single
    /// 16 KiB read rather than the whole `maxHeaderBytes` window.
    static let headerReadStep = 16 * 1024

    /// Longest run of bytes tolerated with no line break before the file is
    /// judged not to be line-structured mail.
    ///
    /// This has to be an ABSOLUTE bound, not a multiple of `windowBytes`.
    /// Deriving it from the window made the refusal threshold depend on an
    /// internal tuning knob: at a 1 MiB window a 5 MB unbroken line was fine,
    /// at a 512-byte window a 4 KB one was refused. A single-line message body
    /// is legal RFC 822 and some mailers emit very long lines, so the bound
    /// belongs to the mail format, not to how much we happen to read at once.
    /// 16 MiB is far past anything legitimate while still bounding memory.
    var maxLineBytes: Int = 16 << 20            // 16 MiB

    /// What a scan found. Locators only: no bodies, no MIME trees.
    struct Scan: Sendable {
        var locators: [MessageLocator] = []
        /// Header blocks, in the same order, decoded leniently.
        var headers: [[String: String]] = []
        /// Messages whose header block hit `maxHeaderBytes`.
        var truncatedHeaderOrdinals: [Int] = []
        var sourcePath: String = ""
        var sourceSize: Int64 = 0

        var messageCount: Int { locators.count }
        var totalMessageBytes: Int64 { locators.reduce(0) { $0 + $1.byteCount } }
        var largestMessageBytes: Int64 { locators.map(\.byteCount).max() ?? 0 }
    }

    // MARK: - Scan

    /// Indexes `fileURL` without decoding any body.
    ///
    /// `onLocator` is awaited as each message boundary closes, so a caller can
    /// stream locators into the store instead of holding the whole index — a
    /// 500 GB source has a lot of messages, and at ~150 bytes each the index
    /// would become the new memory ceiling (10 million messages ≈ 1.5 GB of
    /// locators). Awaiting the callback is what gives backpressure: the scan
    /// cannot outrun the consumer. The returned `Scan` accumulates locators
    /// only when `collect` is true, which is for tests and small files.
    /// `onLocator` is non-optional and NON-escaping on purpose. An optional
    /// closure is implicitly escaping, which would stop a caller from
    /// forwarding its own non-escaping `onBatch` into it — exactly what
    /// `OffsetImportEngine` needs to do.
    func scan(fileURL: URL,
              collect: Bool = true,
              onLocator: (MessageLocator, [String: String]) async throws -> Void = { _, _ in },
              onProgress: ((Double) -> Void)? = nil) async throws -> Scan {

        let size = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ExtractionError.invalidEmail(
                reason: "Cannot open \(fileURL.lastPathComponent) for scanning.")
        }
        defer { try? handle.close() }

        // NOT setting `F_NOCACHE` here, and that is a measured decision rather
        // than an oversight.
        //
        // The hypothesis was that footprint growth came from the unified
        // buffer cache, which `phys_footprint` charges to the process, so
        // asking the kernel to skip caching a file we read exactly once would
        // bound it. A first comparison appeared to show a 10× win (4.3 MiB vs
        // 53.6 MiB on a 48 MiB source) — but that measurement put both scans
        // in ONE process, so the second inherited the first's inflated
        // baseline. Re-measured properly, one configuration per process, same
        // fixture, same position, baseline ~361 MiB both times:
        //
        //     F_NOCACHE ON  → peak delta 29.3 MiB
        //     F_NOCACHE OFF → peak delta 29.5 MiB
        //
        // No effect. Most likely because the fixture is written immediately
        // before being read, so its pages are already resident and a read
        // handle's cache hint cannot evict them. Whether it would help on a
        // genuinely cold file is untested — that needs a cache purge, which
        // needs privileges a test does not have.
        //
        // So the call is gone rather than left in behind a dead flag.
        // Shipping a syscall whose justification was disproven, with a comment
        // claiming a measured reason, is worse than not shipping it; and a
        // disabled branch is worse than both. If someone wants to retry this
        // on a cold volume, the setup is described above and the one line is
        // `fcntl(handle.fileDescriptor, F_NOCACHE, 1)`.

        var scan = Scan()
        scan.sourcePath = fileURL.path
        scan.sourceSize = size

        /// Absolute offsets of every message start, discovered in order.
        var pendingStart: Int64?
        var ordinal = 0

        /// `carry` holds the bytes of the current window plus a tail from the
        /// previous one, so a separator spanning a window edge is still found.
        /// `carryOrigin` is the absolute offset of `carry[0]`.
        var carry = Data()
        var carryOrigin: Int64 = 0
        var reachedEOF = false

        func closeMessage(endingAt end: Int64) async throws {
            guard let start = pendingStart, end > start else { return }
            let range = ByteRange(offset: start, length: end - start)
            let (locator, headers, truncated) =
                try buildLocator(handle: handle, path: fileURL.path,
                                 messageRange: range, ordinal: ordinal)
            ordinal += 1
            if truncated { scan.truncatedHeaderOrdinals.append(locator.ordinal) }
            if collect {
                scan.locators.append(locator)
                scan.headers.append(headers)
            }
            try await onLocator(locator, headers)
        }

        while !reachedEOF {
            try Task.checkCancellation()

            let chunk: Data?
            do { chunk = try handle.read(upToCount: windowBytes) }
            catch {
                // Guard rail: an I/O error is an error. Returning what we have
                // so far as if the file had ended would silently drop mail.
                throw ExtractionError.invalidEmail(
                    reason: "I/O error scanning \(fileURL.lastPathComponent) at offset \((try? handle.offset()) ?? 0): \(error.localizedDescription)")
            }

            if let chunk, !chunk.isEmpty {
                carry.append(chunk)
            } else {
                reachedEOF = true
            }

            // Scan complete lines in `carry`, keeping any partial final line
            // for the next window.
            var cursor = carry.startIndex
            while let newline = carry.range(of: Data([0x0A]), in: cursor..<carry.endIndex) {
                let lineStartIndex = cursor
                let lineData = carry[lineStartIndex..<newline.lowerBound]
                let absoluteLineStart = carryOrigin + Int64(carry.distance(from: carry.startIndex,
                                                                          to: lineStartIndex))

                if Self.isSeparatorLine(lineData) {
                    // The previous message ends where this separator begins.
                    try await closeMessage(endingAt: absoluteLineStart)
                    pendingStart = absoluteLineStart
                }

                cursor = newline.upperBound
            }

            // Retain the unconsumed tail. On EOF there is nothing more coming,
            // so the tail is the last (unterminated) line.
            //
            // Measured, because the obvious reading of the numbers was wrong
            // twice. Per-window footprint sampling on a 48 MiB fixture
            // (2 × 24 MiB bodies) shows footprint climbing to ~26 MiB over the
            // FIRST message and then staying exactly flat for the whole
            // second one. Two attempted "fixes" — rebuilding `carry` from a
            // slice, then forcing a true byte copy — moved the number by less
            // than a megabyte, which is what ruled the buffer out.
            //
            // Flat across the second 24 MiB is the proof it does not leak: a
            // retained read history would have reached 48 MiB+. What the climb
            // is, is allocator high-water — freed 1 MiB read buffers stay in
            // the malloc free list rather than returning to the OS, so
            // `phys_footprint` records the working-set peak once and then
            // reuses it. `testMeasure_peakIsIndependentOfFileSize` pins the
            // property that actually matters: the plateau does not grow when
            // the file does.
            if cursor > carry.startIndex {
                let consumed = carry.distance(from: carry.startIndex, to: cursor)
                carry.removeSubrange(carry.startIndex..<cursor)
                carryOrigin += Int64(consumed)
            }

            if let onProgress, size > 0 {
                onProgress(min(Double(carryOrigin) / Double(size), 1.0))
            }

            // A pathological file with no newline at all must not grow `carry`
            // without bound. The classifier should have caught it, but this
            // cannot be the place that exhausts memory.
            if !reachedEOF, carry.count > maxLineBytes {
                scannerLog.error("no line break in \(carry.count) bytes — abandoning scan of \(fileURL.lastPathComponent, privacy: .public)")
                throw ExtractionError.invalidEmail(
                    reason: "\(fileURL.lastPathComponent) has no line structure in the first \(carry.count) bytes, so it is not a readable mailbox.")
            }
        }

        // Close the final message at end-of-file.
        if pendingStart != nil {
            try await closeMessage(endingAt: size)
        } else if size > 0 {
            // No `From ` separator anywhere: a bare `.eml`. One message, whole
            // file. The streaming parser synthesises an envelope for this case
            // and so does the locator — `envelopeRange` stays nil, which is
            // how a reader knows there was none.
            pendingStart = 0
            try await closeMessage(endingAt: size)
        }

        onProgress?(1.0)
        return scan
    }

    // MARK: - One message

    /// Reads just the header block of a message range and returns its locator.
    /// The body is never read.
    private func buildLocator(handle: FileHandle,
                              path: String,
                              messageRange: ByteRange,
                              ordinal: Int) throws
        -> (MessageLocator, [String: String], truncated: Bool) {

        // Remember where the sequential scan was, and put it back: this is a
        // side read into the same handle.
        let resume = (try? handle.offset()) ?? 0
        defer { try? handle.seek(toOffset: resume) }

        // Read the header block in STEPS, not in one `maxHeaderBytes` gulp.
        //
        // The first version read `min(maxHeaderBytes, messageLength)` — a full
        // 1 MiB for any large message — to find a blank line that in real mail
        // is within the first kilobyte or two.
        //
        // Justified on I/O, which is arithmetic rather than a noisy
        // measurement: on an 8-message fixture this is 128 KiB of header reads
        // instead of 8 MiB, and the ratio grows with message count. It was NOT
        // possible to show a footprint improvement — every absolute
        // `phys_footprint` figure in this file's history turned out to be
        // dominated by process baseline — so the claim made for it is the
        // reduction in bytes read, not a reduction in memory.
        //
        // `maxHeaderBytes` still bounds the total, so a hostile message with
        // no blank line cannot make this unbounded.
        try? handle.seek(toOffset: UInt64(messageRange.offset))
        let limit = Int(min(Int64(maxHeaderBytes), messageRange.length))
        var head = Data()
        var blankLineFound = false
        while head.count < limit {
            let want = min(Self.headerReadStep, limit - head.count)
            let chunk: Data?
            do { chunk = try handle.read(upToCount: want) }
            catch {
                throw ExtractionError.invalidEmail(
                    reason: "I/O error reading headers at offset \(messageRange.offset): \(error.localizedDescription)")
            }
            guard let chunk, !chunk.isEmpty else { break }
            head.append(chunk)
            // Stop as soon as the header terminator is in hand. Searching from
            // the start each time is fine: the search space is bounded by
            // `maxHeaderBytes` and terminates on the first step for real mail.
            if Self.indexOfBlankLine(in: head, from: 0) != nil {
                blankLineFound = true
                break
            }
        }
        _ = blankLineFound   // the ranges below re-derive it; kept for clarity

        // The envelope line, when present.
        var envelopeRange: ByteRange?
        var cursor = 0
        if Self.startsWithSeparator(head) {
            if let firstNewline = head.firstIndex(of: 0x0A) {
                let length = Int64(head.distance(from: head.startIndex, to: firstNewline)) + 1
                envelopeRange = ByteRange(offset: messageRange.offset, length: length)
                cursor = Int(length)
            }
        }

        // Header block ends at the first blank line.
        let blankOffset = Self.indexOfBlankLine(in: head, from: cursor)
        // "Truncated" means we ran out of header budget before finding the
        // blank line — not merely that we stopped reading, since stepping now
        // stops early on purpose whenever the terminator is found.
        let truncated = blankOffset == nil && messageRange.length > Int64(limit)
        let headerEndRelative = blankOffset ?? head.count

        let headerRange = ByteRange(offset: messageRange.offset + Int64(cursor),
                                    length: Int64(headerEndRelative - cursor))
        // Body starts after the blank line's own newline; when there is no
        // blank line the message has no body, and a zero-length range says so
        // rather than a guessed one.
        let bodyStart = blankOffset.map { messageRange.offset + Int64($0) + 1 } ?? messageRange.end
        let bodyRange = ByteRange(offset: min(bodyStart, messageRange.end),
                                  length: max(0, messageRange.end - min(bodyStart, messageRange.end)))

        let headerData = head.subdata(in: cursor..<max(cursor, headerEndRelative))
        let headers = Self.parseHeaders(headerData)

        let locator = MessageLocator(
            sourceDigest: nil,          // filled in by the importer, which hashes the source once
            sourcePath: path,
            messageRange: messageRange,
            envelopeRange: envelopeRange,
            headerRange: headerRange,
            bodyRange: bodyRange,
            ordinal: ordinal
        )
        return (locator, headers, truncated)
    }

    // MARK: - Byte predicates

    private static let fromPrefix = Data("From ".utf8)

    /// The same test the streaming parser applies: `From ` at the start of a
    /// line, plus a 4-digit year. Without the year test, a body line reading
    /// "From the desk of…" would split a message in two.
    static func isSeparatorLine(_ line: Data) -> Bool {
        guard line.count > 5 else { return false }
        guard line.starts(with: fromPrefix) else { return false }
        return containsFourDigitRun(line)
    }

    static func startsWithSeparator(_ data: Data) -> Bool {
        guard let newline = data.firstIndex(of: 0x0A) else {
            return isSeparatorLine(data)
        }
        return isSeparatorLine(data[data.startIndex..<newline])
    }

    /// Four consecutive ASCII digits — the year in an mbox envelope. Done on
    /// bytes to avoid decoding every candidate line into a String.
    private static func containsFourDigitRun(_ data: Data) -> Bool {
        var run = 0
        for byte in data {
            if byte >= 0x30 && byte <= 0x39 {
                run += 1
                if run >= 4 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Offset (relative to `data`) of the blank line that terminates the
    /// header block, or nil if there is none in `data`. Handles both LF and
    /// CRLF: a CRLF mailbox's blank line is `\r\n`, whose "content" is `\r`.
    static func indexOfBlankLine(in data: Data, from start: Int) -> Int? {
        var index = data.index(data.startIndex, offsetBy: min(start, data.count))
        while index < data.endIndex {
            guard let newline = data.range(of: Data([0x0A]), in: index..<data.endIndex) else {
                return nil
            }
            let line = data[index..<newline.lowerBound]
            if line.isEmpty || (line.count == 1 && line.first == 0x0D) {
                return data.distance(from: data.startIndex, to: index)
            }
            index = newline.upperBound
        }
        return nil
    }

    /// Header parse with folded-line (RFC 5322 §2.2.3) continuation.
    ///
    /// Decoded leniently: a mailbox may carry any charset, and a strict UTF-8
    /// failure must not read as "no headers". Repeated fields are joined with
    /// a newline rather than overwritten, because `Received:` chains are
    /// evidence and keeping only the last one loses the path.
    static func parseHeaders(_ data: Data) -> [String: String] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func commit() {
            guard let name = currentName else { return }
            let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = headers[name] {
                headers[name] = existing + "\n" + value
            } else {
                headers[name] = value
            }
            currentName = nil
            currentValue = ""
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Folded continuation of the previous field.
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            commit()
            currentName = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            currentValue = String(line[line.index(after: colon)...])
        }
        commit()
        return headers
    }
}
