//
//  LZMADecoder.swift
//  ArchiveCore
//
//  Completion directive 2026-11-07 §6 "Containers": a pure Swift LZMA and
//  LZMA2 decoder for the 7z reader. Apple's Compression framework decodes
//  only the xz container, not the raw LZMA1 stream 7z folders carry (5-byte
//  properties, no framing) nor LZMA2 chunks, so the decoder is written here
//  from the LZMA specification (lzma-specification.txt / LzmaSpec.cpp in the
//  LZMA SDK, public domain).
//
//  Shape: every stage is a PULL source (`ByteStream.read(upTo:)`), so a
//  solid 7z folder is decoded once, sequentially, and handed out member by
//  member — the consumer asks for the next N bytes and the decoder resumes
//  where it stopped. Output is flushed in 64 KiB windows; the dictionary is
//  the only large allocation, sized min(declared, bytes to decode) and
//  refused above the caller's ceiling (a stated limit, never a silent cap).
//  Corrupt input is an error, never a trap: every distance is checked
//  against the bytes actually in the window and every read against the end
//  of the input.
//

import Foundation

/// A pull source of bytes: `read(upTo:)` returns 1…count bytes, or empty at the end.
protocol ByteStream: AnyObject {
    func read(upTo count: Int) throws -> Data
}

extension ByteStream {
    /// Exactly `count` bytes, or `LZMAError.truncated`.
    func readExactly(_ count: Int) throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk = try read(upTo: count - out.count)
            guard !chunk.isEmpty else { throw LZMAError.truncated }
            out.append(chunk)
        }
        return out
    }

    /// Reads and discards `count` bytes (solid-folder positioning).
    func skip(_ count: Int64) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try read(upTo: Int(min(remaining, 65_536)))
            guard !chunk.isEmpty else { throw LZMAError.truncated }
            remaining -= Int64(chunk.count)
        }
    }
}

/// A stream over an in-memory buffer.
final class DataByteStream: ByteStream {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    func read(upTo count: Int) throws -> Data {
        let take = min(count, data.count - offset)
        guard take > 0 else { return Data() }
        let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + take))
        offset += take
        return chunk
    }
}

/// The first `limit` bytes of another stream (an LZMA2 chunk's packed bytes).
final class LimitedByteStream: ByteStream {
    private let inner: ByteStream
    private(set) var remaining: Int64
    init(_ inner: ByteStream, limit: Int64) { self.inner = inner; self.remaining = limit }
    func read(upTo count: Int) throws -> Data {
        guard remaining > 0 else { return Data() }
        let chunk = try inner.read(upTo: Int(min(Int64(count), remaining)))
        remaining -= Int64(chunk.count)
        return chunk
    }
}

enum LZMAError: Error, CustomStringConvertible, Equatable {
    case truncated
    case corrupt(String)
    case badProperties(String)
    /// The declared dictionary is larger than the run's ceiling — stated, resumable.
    case dictionaryOverLimit(needed: Int64, limit: Int64)

    var description: String {
        switch self {
        case .truncated: return "compressed data ends early"
        case .corrupt(let what): return "LZMA stream is corrupt: \(what)"
        case .badProperties(let what): return "LZMA properties are invalid: \(what)"
        case .dictionaryOverLimit(let needed, let limit): return "needs a \(needed)-byte LZMA dictionary, over the \(limit)-byte guard"
        }
    }
}

// MARK: - Range decoder

final class LZMARangeDecoder {
    private let source: ByteStream
    private var buffer: [UInt8] = []
    private var index = 0
    private(set) var range: UInt32 = 0xFFFF_FFFF
    private(set) var code: UInt32 = 0
    private(set) var corrupted = false

    init(source: ByteStream) { self.source = source }

    /// Reads the five initialisation bytes (a zero, then the first code word).
    func start() throws {
        range = 0xFFFF_FFFF; code = 0; corrupted = false
        let first = try nextByte()
        for _ in 0..<4 { code = (code << 8) | UInt32(try nextByte()) }
        if first != 0 || code == range { corrupted = true }
    }

    var isFinishedOK: Bool { code == 0 }

    @inline(__always) private func nextByte() throws -> UInt8 {
        if index >= buffer.count {
            buffer = [UInt8](try source.read(upTo: 32 * 1024))
            index = 0
            guard !buffer.isEmpty else { throw LZMAError.truncated }
        }
        let b = buffer[index]
        index &+= 1
        return b
    }

    @inline(__always) private func normalize() throws {
        if range < (1 << 24) {
            range <<= 8
            code = (code << 8) | UInt32(try nextByte())
        }
    }

    func decodeDirectBits(_ numBits: Int) throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<numBits {
            range >>= 1
            code = code &- range
            let t = 0 &- (code >> 31)
            code = code &+ (range & t)
            if code == range { corrupted = true }
            try normalize()
            result = (result << 1) &+ (t &+ 1)
        }
        return result
    }

    @inline(__always) func decodeBit(_ prob: inout UInt16) throws -> UInt32 {
        var v = UInt32(prob)
        let bound = (range >> 11) &* v
        let symbol: UInt32
        if code < bound {
            v &+= ((1 << 11) &- v) >> 5
            range = bound
            symbol = 0
        } else {
            v &-= v >> 5
            code &-= bound
            range &-= bound
            symbol = 1
        }
        prob = UInt16(truncatingIfNeeded: v)
        try normalize()
        return symbol
    }

    @inline(__always) func bitTree(_ probs: inout [UInt16], base: Int, numBits: Int) throws -> UInt32 {
        var m: UInt32 = 1
        for _ in 0..<numBits { m = (m << 1) &+ (try decodeBit(&probs[base + Int(m)])) }
        return m &- (UInt32(1) << UInt32(numBits))
    }

    @inline(__always) func reverseBitTree(_ probs: inout [UInt16], base: Int, numBits: Int) throws -> UInt32 {
        var m = 1
        var symbol: UInt32 = 0
        for i in 0..<numBits {
            let bit = try decodeBit(&probs[base + m])
            m = (m << 1) + Int(bit)
            symbol |= bit << UInt32(i)
        }
        return symbol
    }
}

// MARK: - Output window

/// The sliding dictionary, flushed to the consumer in bounded pieces.
struct LZMAOutWindow {
    private var buffer: [UInt8]
    let size: Int
    private(set) var pos = 0
    private(set) var isFull = false
    private(set) var totalPos: UInt64 = 0
    private var flushPos = 0
    private var flushed = Data()

    init(size: Int) {
        self.size = max(size, 1)
        buffer = [UInt8](repeating: 0, count: self.size)
    }

    /// Bytes present in the window (what a distance may reach back to).
    var count: Int { isFull ? size : pos }
    var pendingCount: Int { flushed.count + (pos - flushPos) }

    /// LZMA2 dictionary reset: the bytes not yet handed out stay pending,
    /// the window itself starts empty.
    mutating func reset() {
        if pos > flushPos { flushed.append(contentsOf: buffer[flushPos..<pos]) }
        pos = 0; isFull = false; totalPos = 0; flushPos = 0
    }

    @inline(__always) mutating func putByte(_ b: UInt8) {
        totalPos &+= 1
        buffer[pos] = b
        pos += 1
        if pos == size {
            flushed.append(contentsOf: buffer[flushPos..<size])
            pos = 0; flushPos = 0; isFull = true
        }
    }

    /// The byte `dist` back (1 = the last byte written). `dist` must be ≤ `count`.
    @inline(__always) func getByte(_ dist: Int) -> UInt8 {
        buffer[dist <= pos ? pos - dist : size - dist + pos]
    }

    mutating func copyMatch(dist: Int, length: Int) {
        for _ in 0..<length { putByte(getByte(dist)) }
    }

    /// At most `limit` pending bytes (the caller loops; the ByteStream
    /// contract is "1…count bytes").
    mutating func takePending(upTo limit: Int) -> Data {
        if !flushed.isEmpty {
            if flushed.count <= limit { let out = flushed; flushed = Data(); return out }
            let out = Data(flushed.prefix(limit))
            flushed = Data(flushed.dropFirst(limit))
            return out
        }
        let take = min(limit, pos - flushPos)
        guard take > 0 else { return Data() }
        let out = Data(buffer[flushPos..<(flushPos + take)])
        flushPos += take
        return out
    }
}

// MARK: - LZMA1

struct LZMALenDecoder {
    var choice: UInt16 = 1024
    var choice2: UInt16 = 1024
    var low = [UInt16](repeating: 1024, count: 16 * 8)
    var mid = [UInt16](repeating: 1024, count: 16 * 8)
    var high = [UInt16](repeating: 1024, count: 256)

    mutating func decode(_ rc: LZMARangeDecoder, posState: Int) throws -> UInt32 {
        if try rc.decodeBit(&choice) == 0 { return try rc.bitTree(&low, base: posState * 8, numBits: 3) }
        if try rc.decodeBit(&choice2) == 0 { return 8 + (try rc.bitTree(&mid, base: posState * 8, numBits: 3)) }
        return 16 + (try rc.bitTree(&high, base: 0, numBits: 8))
    }
}

/// The LZMA1 decoder core, also driven chunk by chunk by `LZMA2Decoder`.
final class LZMADecoder: ByteStream {
    struct Properties: Equatable {
        var lc: Int, lp: Int, pb: Int
        var dictSize: UInt32

        /// The 5-byte 7z / .lzma properties: one byte of lc/lp/pb, then the dictionary size.
        init(sevenZipProperties bytes: Data) throws {
            guard bytes.count >= 5 else { throw LZMAError.badProperties("\(bytes.count) bytes, 5 needed") }
            let b = [UInt8](bytes)
            try self.init(lclppb: b[0])
            dictSize = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
        }

        init(lclppb: UInt8) throws {
            var d = Int(lclppb)
            guard d < 9 * 5 * 5 else { throw LZMAError.badProperties("lc/lp/pb byte \(lclppb)") }
            lc = d % 9; d /= 9
            lp = d % 5; pb = d / 5
            dictSize = 1 << 12
        }

        /// LZMA2 dictionary-size byte: 40 = 4 GiB − 1, else (2 | (b & 1)) << (b / 2 + 11).
        static func lzma2DictionarySize(_ b: UInt8) throws -> UInt32 {
            guard b <= 40 else { throw LZMAError.badProperties("LZMA2 dictionary byte \(b)") }
            if b == 40 { return 0xFFFF_FFFF }
            return UInt32(2 | (b & 1)) << UInt32(b / 2 + 11)
        }
    }

    private(set) var properties: Properties
    private var window: LZMAOutWindow
    private var rc: LZMARangeDecoder

    private var literalProbs: [UInt16] = []
    private var posSlotProbs = [UInt16](repeating: 1024, count: 4 * 64)
    private var posDecoders = [UInt16](repeating: 1024, count: 1 + 128 - 14)
    private var alignProbs = [UInt16](repeating: 1024, count: 16)
    private var isMatch = [UInt16](repeating: 1024, count: 12 * 16)
    private var isRep = [UInt16](repeating: 1024, count: 12)
    private var isRepG0 = [UInt16](repeating: 1024, count: 12)
    private var isRepG1 = [UInt16](repeating: 1024, count: 12)
    private var isRepG2 = [UInt16](repeating: 1024, count: 12)
    private var isRep0Long = [UInt16](repeating: 1024, count: 12 * 16)
    private var lenDecoder = LZMALenDecoder()
    private var repLenDecoder = LZMALenDecoder()
    private var state = 0
    private var rep0: UInt32 = 0, rep1: UInt32 = 0, rep2: UInt32 = 0, rep3: UInt32 = 0

    /// Bytes still to produce in the current stream / chunk; nil = until the end marker.
    private var remaining: Int64?
    private var finished = false
    private var started = false

    /// - Parameters:
    ///   - unpackSize: the exact output size when known (7z folders know it), else nil (end marker expected).
    ///   - dictionaryLimit: the largest dictionary this run may allocate; the window is
    ///     min(declared, unpackSize) and refused above the limit with a stated reason.
    init(input: ByteStream, properties: Properties, unpackSize: Int64?, dictionaryLimit: Int64) throws {
        self.properties = properties
        self.rc = LZMARangeDecoder(source: input)
        self.remaining = unpackSize
        let size = try Self.windowSize(declared: properties.dictSize, unpackSize: unpackSize, limit: dictionaryLimit)
        window = LZMAOutWindow(size: size)
        literalProbs = [UInt16](repeating: 1024, count: 0x300 << (properties.lc + properties.lp))
    }

    static func windowSize(declared: UInt32, unpackSize: Int64?, limit: Int64) throws -> Int {
        var needed = Int64(max(declared, 1 << 12))
        if let unpackSize { needed = min(needed, max(unpackSize, 1 << 12)) }
        guard needed <= limit else { throw LZMAError.dictionaryOverLimit(needed: needed, limit: limit) }
        return Int(needed)
    }

    // MARK: Control (used by LZMA2)

    /// Resets state, reps and every probability (an LZMA2 "state reset").
    func resetState() {
        state = 0; rep0 = 0; rep1 = 0; rep2 = 0; rep3 = 0
        for i in literalProbs.indices { literalProbs[i] = 1024 }
        for i in posSlotProbs.indices { posSlotProbs[i] = 1024 }
        for i in posDecoders.indices { posDecoders[i] = 1024 }
        for i in alignProbs.indices { alignProbs[i] = 1024 }
        for i in isMatch.indices { isMatch[i] = 1024 }
        for i in 0..<12 { isRep[i] = 1024; isRepG0[i] = 1024; isRepG1[i] = 1024; isRepG2[i] = 1024 }
        for i in isRep0Long.indices { isRep0Long[i] = 1024 }
        lenDecoder = LZMALenDecoder(); repLenDecoder = LZMALenDecoder()
    }

    /// New lc/lp/pb (an LZMA2 "new properties" chunk); implies a state reset.
    func setProperties(lc: Int, lp: Int, pb: Int) throws {
        guard lc + lp <= 4, pb <= 4 else { throw LZMAError.badProperties("LZMA2 lc+lp \(lc + lp)") }
        properties.lc = lc; properties.lp = lp; properties.pb = pb
        literalProbs = [UInt16](repeating: 1024, count: 0x300 << (lc + lp))
        resetState()
    }

    /// Drops the dictionary (an LZMA2 "dictionary reset"); pending output must have been taken.
    func resetDictionary() { window.reset() }

    /// Begins decoding `unpackSize` bytes from `source` (an LZMA2 chunk).
    func beginChunk(source: ByteStream, unpackSize: Int64) throws {
        rc = LZMARangeDecoder(source: source)
        try rc.start()
        started = true
        remaining = unpackSize
        finished = false
    }

    var isFinished: Bool { finished }
    var pendingCount: Int { window.pendingCount }
    func takePending(upTo limit: Int) -> Data { window.takePending(upTo: limit) }

    /// Writes literal bytes straight into the dictionary (an LZMA2 uncompressed chunk).
    func putUncompressed(_ data: Data) {
        for b in data { window.putByte(b) }
    }

    // MARK: ByteStream

    func read(upTo count: Int) throws -> Data {
        if !started { try rc.start(); started = true }
        if window.pendingCount < count { try decode(wanted: count) }
        return window.takePending(upTo: count)
    }

    /// Decodes until at least `wanted` bytes are pending or the stream ends.
    func decode(wanted: Int) throws {
        let lc = properties.lc, lp = properties.lp, pb = properties.pb
        let dictSize = properties.dictSize
        while !finished && window.pendingCount < wanted {
            if let r = remaining, r == 0 { finished = true; break }
            let posState = Int(window.totalPos & UInt64((1 << pb) - 1))
            let state2 = (state << 4) + posState

            if try rc.decodeBit(&isMatch[state2]) == 0 {
                // Literal
                let prevByte = window.count == 0 ? 0 : window.getByte(1)
                var symbol: UInt32 = 1
                let litState = Int((window.totalPos & UInt64((1 << lp) - 1)) << UInt64(lc)) + Int(prevByte >> UInt8(8 - lc))
                let base = 0x300 * litState
                if state >= 7 {
                    guard Int(rep0) < window.count else { throw LZMAError.corrupt("literal context beyond the window") }
                    var matchByte = UInt32(window.getByte(Int(rep0) + 1))
                    repeat {
                        let matchBit = (matchByte >> 7) & 1
                        matchByte <<= 1
                        let bit = try rc.decodeBit(&literalProbs[base + Int(((1 + matchBit) << 8) + symbol)])
                        symbol = (symbol << 1) | bit
                        if matchBit != bit { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 { symbol = (symbol << 1) | (try rc.decodeBit(&literalProbs[base + Int(symbol)])) }
                window.putByte(UInt8(truncatingIfNeeded: symbol - 0x100))
                state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                if remaining != nil { remaining! -= 1 }
                continue
            }

            var len: UInt32
            if try rc.decodeBit(&isRep[state]) != 0 {
                guard window.count > 0 else { throw LZMAError.corrupt("repeated match before any output") }
                if try rc.decodeBit(&isRepG0[state]) == 0 {
                    if try rc.decodeBit(&isRep0Long[state2]) == 0 {
                        // Short rep: one byte at rep0.
                        guard Int(rep0) < window.count else { throw LZMAError.corrupt("match distance beyond the window") }
                        state = state < 7 ? 9 : 11
                        window.putByte(window.getByte(Int(rep0) + 1))
                        if remaining != nil { remaining! -= 1 }
                        continue
                    }
                } else {
                    let dist: UInt32
                    if try rc.decodeBit(&isRepG1[state]) == 0 {
                        dist = rep1
                    } else {
                        if try rc.decodeBit(&isRepG2[state]) == 0 { dist = rep2 } else { dist = rep3; rep3 = rep2 }
                        rep2 = rep1
                    }
                    rep1 = rep0
                    rep0 = dist
                }
                len = try repLenDecoder.decode(rc, posState: posState)
                state = state < 7 ? 8 : 11
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                len = try lenDecoder.decode(rc, posState: posState)
                state = state < 7 ? 7 : 10
                rep0 = try decodeDistance(len)
                if rep0 == 0xFFFF_FFFF {
                    guard rc.isFinishedOK else { throw LZMAError.corrupt("end marker with a non-zero code") }
                    finished = true
                    break
                }
                guard rep0 < dictSize, Int(rep0) < window.count else { throw LZMAError.corrupt("match distance beyond the window") }
            }
            guard Int(rep0) < window.count else { throw LZMAError.corrupt("match distance beyond the window") }
            var matchLength = Int(len) + 2
            var overran = false
            if let r = remaining, Int64(matchLength) > r { matchLength = Int(r); overran = true }
            window.copyMatch(dist: Int(rep0) + 1, length: matchLength)
            if remaining != nil { remaining! -= Int64(matchLength) }
            if overran { throw LZMAError.corrupt("match runs past the declared size") }
        }
        if rc.corrupted { throw LZMAError.corrupt("range coder out of step") }
    }

    private func decodeDistance(_ len: UInt32) throws -> UInt32 {
        let lenState = Int(min(len, 3))
        let posSlot = Int(try rc.bitTree(&posSlotProbs, base: lenState * 64, numBits: 6))
        if posSlot < 4 { return UInt32(posSlot) }
        let numDirectBits = (posSlot >> 1) - 1
        var dist = UInt32(2 | (posSlot & 1)) << UInt32(numDirectBits)
        if posSlot < 14 {
            dist &+= try rc.reverseBitTree(&posDecoders, base: Int(dist) - posSlot, numBits: numDirectBits)
        } else {
            dist &+= (try rc.decodeDirectBits(numDirectBits - 4)) << 4
            dist &+= try rc.reverseBitTree(&alignProbs, base: 0, numBits: 4)
        }
        return dist
    }
}

// MARK: - LZMA2

/// LZMA2: a sequence of chunks (uncompressed or LZMA, each with its own
/// reset flags) over one shared dictionary.
final class LZMA2Decoder: ByteStream {
    private let input: ByteStream
    private let core: LZMADecoder
    private var chunk: LimitedByteStream?
    private var uncompressedRemaining = 0
    private var ended = false
    private var needProperties = true
    private var needDictionaryReset = true

    /// - Parameter dictionaryByte: the single LZMA2 property byte.
    /// - Parameter unpackSize: the folder's total output when known — bounds the window.
    init(input: ByteStream, dictionaryByte: UInt8, unpackSize: Int64?, dictionaryLimit: Int64) throws {
        self.input = input
        var props = try LZMADecoder.Properties(lclppb: 0)
        props.dictSize = try LZMADecoder.Properties.lzma2DictionarySize(dictionaryByte)
        core = try LZMADecoder(input: DataByteStream(Data()), properties: props, unpackSize: unpackSize, dictionaryLimit: dictionaryLimit)
    }

    func read(upTo count: Int) throws -> Data {
        while !ended && core.pendingCount < count {
            if uncompressedRemaining > 0 {
                let piece = try input.readExactly(min(uncompressedRemaining, 65_536))
                core.putUncompressed(piece)
                uncompressedRemaining -= piece.count
                continue
            }
            if let chunk, !core.isFinished {
                try core.decode(wanted: count)
                if core.isFinished, chunk.remaining > 0 { try chunk.skip(chunk.remaining) }
                continue
            }
            try beginNextChunk()
        }
        return core.takePending(upTo: count)
    }

    private func beginNextChunk() throws {
        let control = try input.readExactly(1)[0]
        if control == 0x00 { ended = true; chunk = nil; return }
        var resetDictionary = false
        if control >= 0xE0 || control == 0x01 {
            needProperties = true
            needDictionaryReset = false
            resetDictionary = true
        } else if needDictionaryReset {
            throw LZMAError.corrupt("LZMA2 stream does not begin with a dictionary reset")
        }
        if control >= 0x80 {
            let sizes = try input.readExactly(4)
            let unpack = (Int64(control & 0x1F) << 16) + Int64(UInt16(sizes[0]) << 8 | UInt16(sizes[1])) + 1
            let pack = Int64(UInt16(sizes[2]) << 8 | UInt16(sizes[3])) + 1
            let mode = (control >> 5) & 0x03
            if mode >= 2 {
                let lclppb = try input.readExactly(1)[0]
                let props = try LZMADecoder.Properties(lclppb: lclppb)
                try core.setProperties(lc: props.lc, lp: props.lp, pb: props.pb)
                needProperties = false
            } else if needProperties {
                throw LZMAError.corrupt("LZMA2 chunk without properties")
            } else if mode == 1 {
                core.resetState()
            }
            if resetDictionary { core.resetDictionary() }
            let limited = LimitedByteStream(input, limit: pack)
            chunk = limited
            try core.beginChunk(source: limited, unpackSize: unpack)
        } else {
            guard control == 0x01 || control == 0x02 else { throw LZMAError.corrupt("LZMA2 control byte \(control)") }
            let sizes = try input.readExactly(2)
            uncompressedRemaining = Int(UInt16(sizes[0]) << 8 | UInt16(sizes[1])) + 1
            if resetDictionary { core.resetDictionary() }
            chunk = nil
        }
    }
}
