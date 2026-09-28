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
//  bytes it ever holds back are the prefix of a line that might still turn
//  out to be `>*From ` (a run of `>` followed by up to five bytes). A line of
//  any length passes through in one append per chunk.
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
    /// the whole text.
    struct StreamingFromLineFilter {
        let mode: FromLineFilterMode
        let enabled: Bool
        /// True when the next byte begins a line.
        private var atLineStart = true
        /// Bytes of the current line held back while it may still be `>*From `.
        private var pending: [UInt8] = []
        /// How many bytes of "From " have matched so far after the `>` run.
        private var fromMatched = 0
        /// The last four bytes emitted, for the record-terminator decision.
        private(set) var tail: [UInt8] = []

        private static let from: [UInt8] = Array("From ".utf8)
        /// A run of `>` longer than this is passed through verbatim: no real
        /// mailbox writer produces it, and holding it back would let one
        /// pathological line grow the pending buffer without bound.
        private static let maxPendingQuotes = 65_536

        init(mode: FromLineFilterMode, enabled: Bool) {
            self.mode = mode
            self.enabled = enabled
        }

        mutating func process(_ chunk: Data) -> Data {
            guard enabled, !chunk.isEmpty else { remember(chunk); return chunk }
            var out = [UInt8]()
            out.reserveCapacity(chunk.count + 8)
            chunk.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var i = 0
                let n = bytes.count
                while i < n {
                    if atLineStart || !pending.isEmpty {
                        let b = bytes[i]
                        i += 1
                        atLineStart = false
                        if fromMatched == 0, b == UInt8(ascii: ">"), pending.count < Self.maxPendingQuotes {
                            pending.append(b)
                            continue
                        }
                        if b == Self.from[fromMatched] {
                            pending.append(b)
                            fromMatched += 1
                            if fromMatched == Self.from.count {
                                decide(into: &out)
                            }
                            continue
                        }
                        // Not a `>*From ` line: everything held back was
                        // literal. The byte itself may be a terminator.
                        out.append(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                        fromMatched = 0
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

        /// The line is `>*From `: apply the mode and release the prefix.
        private mutating func decide(into out: inout [UInt8]) {
            switch mode {
            case .quote:
                out.append(UInt8(ascii: ">"))
                out.append(contentsOf: pending)
            case .unquote:
                if pending.first == UInt8(ascii: ">") {
                    out.append(contentsOf: pending.dropFirst())
                } else {
                    out.append(contentsOf: pending)
                }
            }
            pending.removeAll(keepingCapacity: true)
            fromMatched = 0
        }

        mutating func finish() -> Data {
            // An undecided prefix at the very end is literal.
            let out = pending
            pending = []
            fromMatched = 0
            remember(out)
            return Data(out)
        }

        private mutating func remember<C: Collection>(_ bytes: C) where C.Element == UInt8 {
            guard !bytes.isEmpty else { return }
            tail = Array((tail + Array(bytes.suffix(4))).suffix(4))
        }
    }
}
