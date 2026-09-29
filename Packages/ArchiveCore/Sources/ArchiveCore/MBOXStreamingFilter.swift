//
//  MBOXStreamingFilter.swift
//  ArchiveCore
//
//  Recheck R7 (2026-09-28): the chunk-wise quoter and unquoter used to hold a
//  partial line in a carry buffer and, when a single line outgrew 1 MiB,
//  flushed it and treated the NEXT chunk as if it began at a line start. A
//  `>From ` (or `From `) that happened to sit at that chunk boundary inside
//  the long line was then unquoted (or quoted) — one byte lost or added in
//  the middle of a line, with a valid-looking artifact hash.
//
//  This filter is a byte state machine with bounded memory and no such
//  flush: it knows at every byte whether it is at a line start, and the only
//  state it keeps for a line that might still turn out to be `>*From ` is a
//  COUNT of leading `>` plus up to five bytes of "From ". Third review T5: the
//  count replaces the earlier byte buffer and its 65,536 cap, so the output
//  equals the whole-text functions for a `>` run of any length.
//

import Foundation

extension MBOXRecordBuilder {

    enum FromLineFilterMode: Sendable {
        /// RFC 4155 mboxrd write: a line matching `^>*From ` gains one `>`.
        case quote
        /// mboxrd read: a line matching `^>+From ` loses one `>`.
        case unquote
    }

    /// Line-aware `From ` quoting / unquoting over arbitrary chunk boundaries.
    /// Feed `process` any slicing of the bytes, then `finish`; the output is
    /// identical to `quoteFromLines(bytes:)` / `unquoteFromLines(bytes:)` on
    /// the whole text, for any line length and any run of leading `>`.
    struct StreamingFromLineFilter {
        let mode: FromLineFilterMode
        let enabled: Bool
        /// True when the next byte begins a line.
        private var atLineStart = true
        /// Leading `>` of the current line held back while it may still be `>*From `.
        private var pendingQuotes = 0
        /// Bytes of "From " matched so far after the `>` run (0…5).
        private var fromMatched = 0
        /// The last four bytes emitted, for the record-terminator decision.
        private(set) var tail: [UInt8] = []

        private static let from: [UInt8] = Array("From ".utf8)
        private static let gt = UInt8(ascii: ">")

        init(mode: FromLineFilterMode, enabled: Bool) {
            self.mode = mode
            self.enabled = enabled
        }

        private var scanningPrefix: Bool { pendingQuotes > 0 || fromMatched > 0 }

        mutating func process(_ chunk: Data) -> Data {
            guard enabled, !chunk.isEmpty else { remember(chunk); return chunk }
            var out = [UInt8]()
            out.reserveCapacity(chunk.count + 8)
            chunk.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var i = 0
                let n = bytes.count
                while i < n {
                    if atLineStart || scanningPrefix {
                        let b = bytes[i]
                        i += 1
                        atLineStart = false
                        if fromMatched == 0, b == Self.gt {
                            pendingQuotes += 1
                            continue
                        }
                        if b == Self.from[fromMatched] {
                            fromMatched += 1
                            if fromMatched == Self.from.count {
                                decide(into: &out)
                            }
                            continue
                        }
                        // Not a `>*From ` line: everything held back was
                        // literal. The byte itself may be a terminator.
                        releasePending(into: &out)
                        out.append(b)
                        if b == MBOXRecordBuilder.lf || b == MBOXRecordBuilder.cr { atLineStart = true }
                        continue
                    }
                    // Pass-through to the end of the line, one append.
                    var j = i
                    while j < n, bytes[j] != MBOXRecordBuilder.lf, bytes[j] != MBOXRecordBuilder.cr { j += 1 }
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[i..<j]))
                    if j < n {
                        out.append(bytes[j])
                        atLineStart = true
                        j += 1
                    }
                    i = j
                }
            }
            remember(out)
            return Data(out)
        }

        /// The held-back prefix as it was read: the `>` run and the partial "From ".
        private mutating func releasePending(into out: inout [UInt8]) {
            out.append(contentsOf: repeatElement(Self.gt, count: pendingQuotes))
            out.append(contentsOf: Self.from[0..<fromMatched])
            pendingQuotes = 0
            fromMatched = 0
        }

        /// The line is `>*From `: apply the mode and release the prefix.
        private mutating func decide(into out: inout [UInt8]) {
            switch mode {
            case .quote:
                out.append(contentsOf: repeatElement(Self.gt, count: pendingQuotes + 1))
            case .unquote:
                out.append(contentsOf: repeatElement(Self.gt, count: max(0, pendingQuotes - 1)))
            }
            out.append(contentsOf: Self.from)
            pendingQuotes = 0
            fromMatched = 0
        }

        mutating func finish() -> Data {
            // An undecided prefix at the very end is literal.
            var out = [UInt8]()
            releasePending(into: &out)
            remember(out)
            return Data(out)
        }

        private mutating func remember<C: Collection>(_ bytes: C) where C.Element == UInt8 {
            guard !bytes.isEmpty else { return }
            tail = Array((tail + Array(bytes.suffix(4))).suffix(4))
        }
    }
}
