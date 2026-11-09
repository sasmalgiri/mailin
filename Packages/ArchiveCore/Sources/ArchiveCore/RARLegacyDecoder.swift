//
//  RARLegacyDecoder.swift
//  ArchiveCore
//
//  Owner decision 2026-11-09: the RAR 1.5 (unpack version 15) and RAR 2.0
//  (unpack versions 20 and 26) compression algorithms, decoded by mailin's
//  own Swift code. libarchive implements only the RAR 2.9–4.x and RAR 5.0
//  algorithms. There is no formal specification of these two algorithms;
//  the behaviour (bit order, the adaptive tables of RAR 1.5, the Huffman
//  layout, the repeat codes, the RAR 2.0 multimedia (audio) predictor and
//  its constants) was learned by reading the freely published UnRAR source
//  (unrarsrc 7.3.2, unpack15.cpp / unpack20.cpp, rarlab.com) and written
//  here from that understanding — no code was copied from UnRAR, The
//  Unarchiver/XADMaster or 7-Zip. The constant tables are the format's own
//  numbers. Sources are listed in Fixtures/rar-legacy/MANIFEST.md.
//
//  Verified on real archives written by RAR 1.5x and RAR 2.x (junrar's and
//  rarfile's public test files): every member's CRC-32 from its header.
//  Solid RAR 1.5/2.0 streams after their first member and RAR 1.5/2.0
//  encryption are not opened (no public real file to verify them on).
//
//  The decoder streams: the packed data is read in 64 KiB chunks and the
//  output leaves through a 4 MiB window (RAR 2.0's largest dictionary is
//  1 MiB), so a member of any size needs the same memory.
//

import Foundation

extension RARReader {

    /// Unpack versions this file decodes.
    static let legacyAlgorithmVersions: Set<Int> = [15, 20, 26]

    enum LegacyDecodeError: Error, CustomStringConvertible {
        case truncated
        case badTables
        var description: String {
            switch self {
            case .truncated: return "the compressed data ends before the member is complete"
            case .badTables: return "the Huffman tables are malformed"
            }
        }
    }

    /// Bits are read most significant first from a byte stream that is
    /// fetched in chunks; past the member's data the stream reads zeros
    /// (as the format's look-ahead expects) up to a small slack, then fails.
    struct LegacyBitInput {
        private let source: RandomAccessSource
        private let start: Int64
        private let length: Int64
        private var bytes: [UInt8] = []
        /// File position (relative to `start`) of `bytes[0]`.
        private var base: Int64 = 0
        private var fetched: Int64 = 0
        /// Bit position inside `bytes`.
        private var bit = 0
        private static let chunk = 64 * 1024
        private static let slack: Int64 = 64

        init(source: RandomAccessSource, offset: Int64, length: Int64) {
            self.source = source
            start = offset
            self.length = length
        }

        private mutating func refill() throws {
            let consumed = bit >> 3
            if consumed > 0 {
                bytes.removeFirst(consumed)
                base += Int64(consumed)
                bit &= 7
            }
            while bytes.count < 16 {
                if fetched < length {
                    let n = Int(min(Int64(Self.chunk), length - fetched))
                    let data = try source.read(at: start + fetched, count: n)
                    guard !data.isEmpty else { throw LegacyDecodeError.truncated }
                    bytes.append(contentsOf: data)
                    fetched += Int64(data.count)
                } else {
                    guard base + Int64(bytes.count) < length + Self.slack else { throw LegacyDecodeError.truncated }
                    bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
                }
            }
        }

        /// The next 16 bits (not consumed).
        mutating func peek16() throws -> UInt32 {
            if bytes.count - (bit >> 3) < 4 { try refill() }
            let i = bit >> 3
            let v = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            return (v >> (8 - UInt32(bit & 7))) & 0xFFFF
        }

        mutating func skip(_ n: Int) { bit += n }

        /// Reads and consumes `n` (1…16) bits.
        mutating func take(_ n: Int) throws -> UInt32 {
            let v = try peek16() >> UInt32(16 - n)
            skip(n)
            return v
        }

        /// True once more than the slack beyond the data has been consumed.
        var isPastEnd: Bool { base + Int64(bit >> 3) > length + Self.slack / 2 }
    }

    /// A canonical Huffman code as RAR 2.x builds it: codes ordered by
    /// length, then by symbol; a code is read from the next 15 bits.
    struct LegacyHuffman {
        private var limit = [UInt32](repeating: 0, count: 16)   // left-aligned first code past each length
        private var firstIndex = [Int](repeating: 0, count: 16)
        private var symbols: [UInt16] = []
        private var size = 0

        init() {}

        init(lengths: ArraySlice<UInt8>) {
            size = lengths.count
            var count = [Int](repeating: 0, count: 16)
            for l in lengths { count[Int(l & 0x0F)] += 1 }
            count[0] = 0
            var upper: UInt32 = 0
            for len in 1..<16 {
                upper += UInt32(count[len])
                limit[len] = upper << UInt32(16 - len)
                upper <<= 1
                firstIndex[len] = firstIndex[len - 1] + count[len - 1]
            }
            var next = firstIndex
            symbols = [UInt16](repeating: 0, count: max(size, 1))
            for (symbol, l) in lengths.enumerated() where l & 0x0F != 0 {
                let len = Int(l & 0x0F)
                if next[len] < symbols.count { symbols[next[len]] = UInt16(symbol) }
                next[len] += 1
            }
        }

        func decode(_ input: inout LegacyBitInput) throws -> Int {
            let field = try input.peek16() & 0xFFFE
            var len = 15
            for l in 1..<15 where field < limit[l] { len = l; break }
            input.skip(len)
            let offset = Int((field &- limit[len - 1]) >> UInt32(16 - len))
            let position = firstIndex[len] + offset
            return position >= 0 && position < size ? Int(symbols[position]) : Int(symbols.first ?? 0)
        }
    }

    /// The output side: a 4 MiB ring that zero-fills a copy reaching before
    /// the first byte (as a zeroed RAR window reads) and hands bytes on in order.
    struct LegacyWindow {
        static let size = 1 << 22
        static let mask = size - 1
        var bytes = [UInt8](repeating: 0, count: size)
        var position = 0
        var produced: Int64 = 0
        var flushed: Int64 = 0
        let limit: Int64

        init(limit: Int64) { self.limit = limit }

        mutating func put(_ b: UInt8) {
            bytes[position] = b
            position = (position + 1) & Self.mask
            produced += 1
        }

        mutating func copy(length: Int, distance: UInt32) {
            let d = Int(distance)
            if distance == 0 || Int64(d) > min(produced, Int64(Self.size)) {
                for _ in 0..<length { put(0) }
                return
            }
            for _ in 0..<length { put(bytes[(position - d) & Self.mask]) }
        }

        /// Hands on what is ready (all of it when `final`); never past `limit`.
        mutating func flush(final: Bool, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
            let ready = min(produced, limit)
            guard ready > flushed, final || ready - flushed >= Int64(Self.size / 4) else { return }
            var from = Int(flushed & Int64(Self.mask))
            var left = Int(ready - flushed)
            while left > 0 {
                let n = min(left, Self.size - from)
                try bytes.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[from..<(from + n)])) }
                left -= n
                from = (from + n) & Self.mask
            }
            flushed = ready
        }
    }

    /// Decodes one RAR 1.5 / 2.0 member (non-solid) and passes its bytes to
    /// `sink` in order; exactly `unpackedSize` bytes unless the data fails.
    static func decodeLegacy(version: Int, source: RandomAccessSource, offset: Int64, packedSize: Int64,
                             unpackedSize: Int64, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        var input = LegacyBitInput(source: source, offset: offset, length: packedSize)
        var window = LegacyWindow(limit: unpackedSize)
        guard unpackedSize > 0 else { return }
        switch version {
        case 15:
            var state = RAR15State()
            try state.run(&input, &window, sink: sink)
        case 20, 26:
            var state = RAR20State()
            try state.run(&input, &window, sink: sink)
        default:
            throw ReadError.malformed("unpack version \(version) is not a RAR 1.5/2.0 algorithm")
        }
        try window.flush(final: true, sink: sink)
    }

    // MARK: - RAR 2.0

    struct RAR20State {
        // The format's length and distance bases and extra-bit counts.
        private static let lengthBase: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224]
        private static let lengthBits: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
        private static let distanceBase: [UInt32] = [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072,
                                                     4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304, 131072, 196608, 262144, 327680,
                                                     393216, 458752, 524288, 589824, 655360, 720896, 786432, 851968, 917504, 983040]
        private static let distanceBits: [UInt8] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
                                                    14, 14, 15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16]
        private static let shortBase: [UInt8] = [0, 4, 8, 16, 32, 64, 128, 192]
        private static let shortBits: [UInt8] = [2, 2, 3, 4, 5, 6, 6, 6]
        // Alphabet sizes: literals+lengths, distances, repeat lengths, the
        // bit-length code, one audio channel.
        private static let nc = 298, dc = 48, rc = 28, bc = 19, mc = 257

        private var literals = LegacyHuffman(), distances = LegacyHuffman(), repeats = LegacyHuffman()
        private var audioCodes = [LegacyHuffman](repeating: LegacyHuffman(), count: 4)
        private var previousLengths = [UInt8](repeating: 0, count: 257 * 4)
        private var recent = [UInt32](repeating: 0xFFFF_FFFF, count: 4)
        private var recentIndex = 0
        private var lastDistance: UInt32 = 0xFFFF_FFFF
        private var lastLength = 0
        private var audio = false
        private var channels = 1
        private var channel = 0
        private var channelDelta: Int32 = 0
        private var predictors = [AudioPredictor](repeating: AudioPredictor(), count: 4)

        /// One channel's adaptive linear predictor (RAR 2.0 multimedia mode).
        struct AudioPredictor {
            var k = [Int32](repeating: 0, count: 5)
            var d = [Int32](repeating: 0, count: 4)
            var lastDelta: Int32 = 0
            var error = [UInt32](repeating: 0, count: 11)
            var count: UInt32 = 0
            var lastChar: Int32 = 0
        }

        private mutating func copy(_ length: Int, _ distance: UInt32, _ window: inout LegacyWindow) {
            lastDistance = distance
            recent[recentIndex] = distance
            recentIndex = (recentIndex + 1) & 3
            lastLength = length
            window.copy(length: length, distance: distance)
        }

        private mutating func readTables(_ input: inout LegacyBitInput) throws {
            let head = try input.peek16()
            audio = head & 0x8000 != 0
            if head & 0x4000 == 0 { for i in previousLengths.indices { previousLengths[i] = 0 } }
            input.skip(2)
            let total: Int
            if audio {
                channels = Int((head >> 12) & 3) + 1
                if channel >= channels { channel = 0 }
                input.skip(2)
                total = Self.mc * channels
            } else {
                total = Self.nc + Self.dc + Self.rc
            }
            var bitLengths = [UInt8](repeating: 0, count: Self.bc)
            for i in 0..<Self.bc { bitLengths[i] = UInt8(try input.take(4)) }
            let lengthCode = LegacyHuffman(lengths: bitLengths[...])
            var table = [UInt8](repeating: 0, count: total)
            var i = 0
            while i < total {
                let code = try lengthCode.decode(&input)
                switch code {
                case 0..<16:
                    table[i] = UInt8((code + Int(previousLengths[i])) & 0x0F)
                    i += 1
                case 16:
                    guard i > 0 else { throw LegacyDecodeError.badTables }
                    var n = Int(try input.take(2)) + 3
                    while n > 0, i < total { table[i] = table[i - 1]; i += 1; n -= 1 }
                default:
                    var n = code == 17 ? Int(try input.take(3)) + 3 : Int(try input.take(7)) + 11
                    while n > 0, i < total { table[i] = 0; i += 1; n -= 1 }
                }
            }
            if audio {
                for c in 0..<channels { audioCodes[c] = LegacyHuffman(lengths: table[(c * Self.mc)..<((c + 1) * Self.mc)]) }
            } else {
                literals = LegacyHuffman(lengths: table[0..<Self.nc])
                distances = LegacyHuffman(lengths: table[Self.nc..<(Self.nc + Self.dc)])
                repeats = LegacyHuffman(lengths: table[(Self.nc + Self.dc)..<total])
            }
            for j in 0..<total { previousLengths[j] = table[j] }
        }

        private mutating func decodeAudio(_ delta: Int32) -> UInt8 {
            var v = predictors[channel]
            v.count &+= 1
            v.d[3] = v.d[2]
            v.d[2] = v.d[1]
            v.d[1] = v.lastDelta &- v.d[0]
            v.d[0] = v.lastDelta
            var predicted = 8 &* v.lastChar &+ v.k[0] &* v.d[0] &+ v.k[1] &* v.d[1] &+ v.k[2] &* v.d[2] &+ v.k[3] &* v.d[3] &+ v.k[4] &* channelDelta
            predicted = (predicted >> 3) & 0xFF
            let ch = predicted &- delta
            let d = Int32(Int8(truncatingIfNeeded: delta)) &* 8
            let candidates: [Int32] = [d, d &- v.d[0], d &+ v.d[0], d &- v.d[1], d &+ v.d[1], d &- v.d[2], d &+ v.d[2],
                                       d &- v.d[3], d &+ v.d[3], d &- channelDelta, d &+ channelDelta]
            for (i, c) in candidates.enumerated() { v.error[i] &+= c.magnitude }
            v.lastDelta = Int32(Int8(truncatingIfNeeded: ch &- v.lastChar))
            channelDelta = v.lastDelta
            v.lastChar = ch
            if v.count & 0x1F == 0 {
                // Every 32 samples, nudge the coefficient whose sign flip would have erred least.
                var best = 0
                var smallest = v.error[0]
                for i in 1..<11 where v.error[i] < smallest { smallest = v.error[i]; best = i }
                for i in 0..<11 { v.error[i] = 0 }
                if best > 0 {
                    let k = (best - 1) / 2
                    if best % 2 == 1 { if v.k[k] >= -16 { v.k[k] -= 1 } } else { if v.k[k] < 16 { v.k[k] += 1 } }
                }
            }
            predictors[channel] = v
            return UInt8(truncatingIfNeeded: ch)
        }

        mutating func run(_ input: inout LegacyBitInput, _ window: inout LegacyWindow,
                          sink: (UnsafeRawBufferPointer) throws -> Void) throws {
            try readTables(&input)
            while window.produced < window.limit {
                if input.isPastEnd { throw LegacyDecodeError.truncated }
                try window.flush(final: false, sink: sink)
                if audio {
                    let n = try audioCodes[channel].decode(&input)
                    if n == 256 { try readTables(&input); continue }
                    window.put(decodeAudio(Int32(n)))
                    channel += 1
                    if channel == channels { channel = 0 }
                    continue
                }
                let n = try literals.decode(&input)
                switch n {
                case 0..<256:
                    window.put(UInt8(n))
                case 270...:
                    let slot = n - 270
                    guard slot < Self.lengthBase.count else { throw LegacyDecodeError.badTables }
                    var length = Int(Self.lengthBase[slot]) + 3
                    let lb = Int(Self.lengthBits[slot])
                    if lb > 0 { length += Int(try input.take(lb)) }
                    let ds = try distances.decode(&input)
                    guard ds < Self.distanceBase.count else { throw LegacyDecodeError.badTables }
                    var distance = Self.distanceBase[ds] + 1
                    let db = Int(Self.distanceBits[ds])
                    if db > 0 { distance += try input.take(db) }
                    if distance >= 0x2000 {
                        length += 1
                        if distance >= 0x40000 { length += 1 }
                    }
                    copy(length, distance, &window)
                case 269:
                    try readTables(&input)
                case 256:
                    copy(lastLength, lastDistance, &window)
                case 257..<261:
                    let distance = recent[(recentIndex - (n - 256)) & 3]
                    let slot = try repeats.decode(&input)
                    guard slot < Self.lengthBase.count else { throw LegacyDecodeError.badTables }
                    var length = Int(Self.lengthBase[slot]) + 2
                    let lb = Int(Self.lengthBits[slot])
                    if lb > 0 { length += Int(try input.take(lb)) }
                    if distance >= 0x101 {
                        length += 1
                        if distance >= 0x2000 {
                            length += 1
                            if distance >= 0x40000 { length += 1 }
                        }
                    }
                    copy(length, distance, &window)
                default:   // 261…268: short distance, length 2
                    let slot = n - 261
                    var distance = UInt32(Self.shortBase[slot]) + 1
                    let sb = Int(Self.shortBits[slot])
                    if sb > 0 { distance += try input.take(sb) }
                    copy(2, distance, &window)
                }
            }
        }
    }

    // MARK: - RAR 1.5

    /// RAR 1.5: no transmitted tables — fixed prefix-code families chosen by
    /// running averages, and move-to-front-like symbol lists that adapt as
    /// bytes, lengths and distances are seen.
    struct RAR15State {
        /// A fixed code family: `bounds` are the left-aligned code limits, `bases` the first value per length.
        private struct Family {
            let start: Int
            let bounds: [UInt32]
            let bases: [UInt32]
        }
        private static let l1 = Family(start: 2, bounds: [0x8000, 0xa000, 0xc000, 0xd000, 0xe000, 0xea00, 0xee00, 0xf000, 0xf200, 0xf200, 0xffff],
                                       bases: [0, 0, 0, 2, 3, 5, 7, 11, 16, 20, 24, 32, 32])
        private static let l2 = Family(start: 3, bounds: [0xa000, 0xc000, 0xd000, 0xe000, 0xea00, 0xee00, 0xf000, 0xf200, 0xf240, 0xffff],
                                       bases: [0, 0, 0, 0, 5, 7, 9, 13, 18, 22, 26, 34, 36])
        private static let hf0 = Family(start: 4, bounds: [0x8000, 0xc000, 0xe000, 0xf200, 0xf200, 0xf200, 0xf200, 0xf200, 0xffff],
                                        bases: [0, 0, 0, 0, 0, 8, 16, 24, 33, 33, 33, 33, 33])
        private static let hf1 = Family(start: 5, bounds: [0x2000, 0xc000, 0xe000, 0xf000, 0xf200, 0xf200, 0xf7e0, 0xffff],
                                        bases: [0, 0, 0, 0, 0, 0, 4, 44, 60, 76, 80, 80, 127])
        private static let hf2 = Family(start: 5, bounds: [0x1000, 0x2400, 0x8000, 0xc000, 0xfa00, 0xffff, 0xffff, 0xffff],
                                        bases: [0, 0, 0, 0, 0, 0, 2, 7, 53, 117, 233, 0, 0])
        private static let hf3 = Family(start: 6, bounds: [0x800, 0x2400, 0xee00, 0xfe80, 0xffff, 0xffff, 0xffff],
                                        bases: [0, 0, 0, 0, 0, 0, 0, 2, 16, 218, 251, 0, 0])
        private static let hf4 = Family(start: 8, bounds: [0xff00, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff],
                                        bases: [0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0])
        // Short-match length codes: code lengths and the bit patterns they match.
        private static let shortLength1: [Int] = [1, 3, 4, 4, 5, 6, 7, 8, 8, 4, 4, 5, 6, 6, 4, 0]
        private static let shortPattern1: [UInt32] = [0, 0xa0, 0xd0, 0xe0, 0xf0, 0xf8, 0xfc, 0xfe, 0xff, 0xc0, 0x80, 0x90, 0x98, 0x9c, 0xb0, 0]
        private static let shortLength2: [Int] = [2, 3, 3, 3, 4, 4, 5, 6, 6, 4, 4, 5, 6, 6, 4, 0]
        private static let shortPattern2: [UInt32] = [0, 0x40, 0x60, 0xa0, 0xd0, 0xe0, 0xf0, 0xf8, 0xfc, 0xc0, 0x80, 0x90, 0x98, 0x9c, 0xb0, 0]

        // Adaptive symbol lists (high byte = symbol, low byte = its counter) and their per-counter positions.
        private var bytes = [UInt16](repeating: 0, count: 256)
        private var distancesA = [UInt16](repeating: 0, count: 256)
        private var distancesB = [UInt16](repeating: 0, count: 256)
        private var flagSymbols = [UInt16](repeating: 0, count: 256)
        private var bytePlace = [UInt8](repeating: 0, count: 256)
        private var distancePlaceB = [UInt8](repeating: 0, count: 256)
        private var flagPlace = [UInt8](repeating: 0, count: 256)

        private var avgPlace: UInt32 = 0x3500, avgPlaceB: UInt32 = 0
        private var avgLength1: UInt32 = 0, avgLength2: UInt32 = 0, avgLength3: UInt32 = 0
        private var huffmanRun: UInt32 = 0, buf60: UInt32 = 0
        private var maxDistance3: UInt32 = 0x2001
        private var literalWeight: UInt32 = 0x80, matchWeight: UInt32 = 0x80
        private var flags: UInt32 = 0
        private var flagCount = 0
        private var literalMode = false
        private var repeatCount = 0
        private var recent = [UInt32](repeating: 0xFFFF_FFFF, count: 4)
        private var recentIndex = 0
        private var lastDistance: UInt32 = 0xFFFF_FFFF
        private var lastLength = 0
        /// Bytes still owed (signed: the loop ends once it goes below zero).
        private var owed: Int64 = 0

        init() {
            for i in 0..<256 {
                bytes[i] = UInt16(i) << 8
                distancesB[i] = UInt16(i) << 8
                distancesA[i] = UInt16(i)
                flagSymbols[i] = UInt16(truncatingIfNeeded: ((~i &+ 1) & 0xFF) << 8)
            }
            Self.reset(&distancesB, &distancePlaceB)
        }

        /// Restarts a list's counters: eight groups of 32 entries counted 7 down to 0.
        private static func reset(_ list: inout [UInt16], _ places: inout [UInt8]) {
            var k = 0
            for group in stride(from: 7, through: 0, by: -1) {
                for _ in 0..<32 { list[k] = (list[k] & 0xFF00) | UInt16(group); k += 1 }
            }
            for i in places.indices { places[i] = 0 }
            for group in stride(from: 6, through: 0, by: -1) { places[group] = UInt8((7 - group) * 32) }
        }

        private func decode(_ field: UInt32, _ family: Family, _ input: inout LegacyBitInput) -> UInt32 {
            let value = field & 0xFFF0
            var bits = family.start
            var i = 0
            while family.bounds[i] <= value { bits += 1; i += 1 }
            input.skip(bits)
            let below = i > 0 ? family.bounds[i - 1] : 0
            return ((value &- below) >> UInt32(16 - bits)) &+ family.bases[bits]
        }

        private mutating func copy(_ distance: UInt32, _ length: Int, _ window: inout LegacyWindow) {
            owed -= Int64(length)
            window.copy(length: length, distance: distance)
        }

        private mutating func remember(_ distance: UInt32, _ length: Int) {
            recent[recentIndex] = distance
            recentIndex = (recentIndex + 1) & 3
            lastLength = length
            lastDistance = distance
        }

        private mutating func nextFlags(_ input: inout LegacyBitInput) throws {
            let place = Int(decode(try input.peek16(), Self.hf2, &input))
            guard place < 256 else { return }
            var symbol: UInt32
            var newPlace: Int
            while true {
                symbol = UInt32(flagSymbols[place])
                flags = symbol >> 8
                newPlace = Int(flagPlace[Int(symbol & 0xFF)])
                flagPlace[Int(symbol & 0xFF)] &+= 1
                symbol += 1
                if symbol & 0xFF != 0 { break }
                Self.reset(&flagSymbols, &flagPlace)
            }
            flagSymbols[place] = flagSymbols[newPlace]
            flagSymbols[newPlace] = UInt16(truncatingIfNeeded: symbol)
        }

        private mutating func shortMatch(_ input: inout LegacyBitInput, _ window: inout LegacyWindow) throws {
            huffmanRun = 0
            var field = try input.peek16()
            if repeatCount == 2 {
                input.skip(1)
                if field >= 0x8000 { copy(lastDistance, lastLength, &window); return }
                field <<= 1
                repeatCount = 0
            }
            field >>= 8
            var code = 0
            if avgLength1 < 37 {
                while true {
                    let len = code == 1 ? Int(buf60) + 3 : Self.shortLength1[code]
                    if (field ^ Self.shortPattern1[code]) & ~(UInt32(0xFF) >> UInt32(len)) == 0 { break }
                    code += 1
                }
                input.skip(code == 1 ? Int(buf60) + 3 : Self.shortLength1[code])
            } else {
                while true {
                    let len = code == 3 ? Int(buf60) + 3 : Self.shortLength2[code]
                    if (field ^ Self.shortPattern2[code]) & ~(UInt32(0xFF) >> UInt32(len)) == 0 { break }
                    code += 1
                }
                input.skip(code == 3 ? Int(buf60) + 3 : Self.shortLength2[code])
            }
            if code >= 9 {
                if code == 9 {
                    repeatCount += 1
                    copy(lastDistance, lastLength, &window)
                    return
                }
                if code == 14 {
                    repeatCount = 0
                    let length = Int(decode(try input.peek16(), Self.l2, &input)) + 5
                    let distance = (try input.peek16() >> 1) | 0x8000
                    input.skip(15)
                    lastLength = length
                    lastDistance = distance
                    copy(distance, length, &window)
                    return
                }
                repeatCount = 0
                let saved = code
                let distance = recent[(recentIndex - (code - 9)) & 3]
                var length = Int(decode(try input.peek16(), Self.l1, &input)) + 2
                if length == 0x101 && saved == 10 { buf60 ^= 1; return }
                if distance > 256 { length += 1 }
                if distance >= maxDistance3 { length += 1 }
                remember(distance, length)
                copy(distance, length, &window)
                return
            }
            repeatCount = 0
            avgLength1 = avgLength1 &+ UInt32(code)
            avgLength1 = avgLength1 &- (avgLength1 >> 4)
            var place = Int(decode(try input.peek16(), Self.hf2, &input) & 0xFF)
            var distance = UInt32(distancesA[place])
            place -= 1
            if place != -1 {
                let previous = distancesA[place]
                distancesA[place + 1] = previous
                distancesA[place] = UInt16(truncatingIfNeeded: distance)
            }
            let length = code + 2
            distance += 1
            remember(distance, length)
            copy(distance, length, &window)
        }

        private mutating func longMatch(_ input: inout LegacyBitInput, _ window: inout LegacyWindow) throws {
            huffmanRun = 0
            matchWeight += 16
            if matchWeight > 0xFF { matchWeight = 0x90; literalWeight >>= 1 }
            let previousAvg2 = avgLength2
            var field = try input.peek16()
            var length: Int
            if avgLength2 >= 122 {
                length = Int(decode(field, Self.l2, &input))
            } else if avgLength2 >= 64 {
                length = Int(decode(field, Self.l1, &input))
            } else if field < 0x100 {
                length = Int(field)
                input.skip(16)
            } else {
                length = 0
                while (field << UInt32(length)) & 0x8000 == 0 { length += 1 }
                input.skip(length + 1)
            }
            avgLength2 = avgLength2 &+ UInt32(length)
            avgLength2 = avgLength2 &- (avgLength2 >> 5)

            field = try input.peek16()
            let place: Int
            if avgPlaceB > 0x28FF { place = Int(decode(field, Self.hf2, &input)) }
            else if avgPlaceB > 0x6FF { place = Int(decode(field, Self.hf1, &input)) }
            else { place = Int(decode(field, Self.hf0, &input)) }
            avgPlaceB = avgPlaceB &+ UInt32(place)
            avgPlaceB = avgPlaceB &- (avgPlaceB >> 8)
            var symbol: UInt32
            var newPlace: Int
            while true {
                symbol = UInt32(distancesB[place & 0xFF])
                newPlace = Int(distancePlaceB[Int(symbol & 0xFF)])
                distancePlaceB[Int(symbol & 0xFF)] &+= 1
                symbol += 1
                if symbol & 0xFF != 0 { break }
                Self.reset(&distancesB, &distancePlaceB)
            }
            distancesB[place & 0xFF] = distancesB[newPlace]
            distancesB[newPlace] = UInt16(truncatingIfNeeded: symbol)
            let distance = ((symbol & 0xFF00) | (try input.peek16() >> 8)) >> 1
            input.skip(7)

            let previousAvg3 = avgLength3
            if length != 1 && length != 4 {
                if length == 0 && distance <= maxDistance3 {
                    avgLength3 = avgLength3 &+ 1
                    avgLength3 = avgLength3 &- (avgLength3 >> 8)
                } else if avgLength3 > 0 {
                    avgLength3 -= 1
                }
            }
            length += 3
            if distance >= maxDistance3 { length += 1 }
            if distance <= 256 { length += 8 }
            maxDistance3 = previousAvg3 > 0xB0 || (avgPlace >= 0x2A00 && previousAvg2 < 0x40) ? 0x7F00 : 0x2001
            remember(distance, length)
            copy(distance, length, &window)
        }

        private mutating func literal(_ input: inout LegacyBitInput, _ window: inout LegacyWindow) throws {
            let field = try input.peek16()
            var place: Int
            if avgPlace > 0x75FF { place = Int(decode(field, Self.hf4, &input)) }
            else if avgPlace > 0x5DFF { place = Int(decode(field, Self.hf3, &input)) }
            else if avgPlace > 0x35FF { place = Int(decode(field, Self.hf2, &input)) }
            else if avgPlace > 0x0DFF { place = Int(decode(field, Self.hf1, &input)) }
            else { place = Int(decode(field, Self.hf0, &input)) }
            place &= 0xFF
            if literalMode {
                if place == 0 && field > 0xFFF { place = 0x100 }
                place -= 1
                if place == -1 {
                    // Escape out of the run of literals, or a short match inside it.
                    let escape = try input.peek16()
                    input.skip(1)
                    if escape & 0x8000 != 0 { huffmanRun = 0; literalMode = false; return }
                    let length = escape & 0x4000 != 0 ? 4 : 3
                    input.skip(1)
                    var distance = decode(try input.peek16(), Self.hf2, &input)
                    distance = (distance << 5) | (try input.peek16() >> 11)
                    input.skip(5)
                    copy(distance, length, &window)
                    return
                }
            } else {
                let run = huffmanRun
                huffmanRun += 1
                if run >= 16 && flagCount == 0 { literalMode = true }
            }
            avgPlace = avgPlace &+ UInt32(place)
            avgPlace = avgPlace &- (avgPlace >> 8)
            literalWeight += 16
            if literalWeight > 0xFF { literalWeight = 0x90; matchWeight >>= 1 }
            window.put(UInt8(truncatingIfNeeded: bytes[place] >> 8))
            owed -= 1
            var symbol: UInt32
            var newPlace: Int
            while true {
                symbol = UInt32(bytes[place])
                newPlace = Int(bytePlace[Int(symbol & 0xFF)])
                bytePlace[Int(symbol & 0xFF)] &+= 1
                symbol += 1
                if symbol & 0xFF > 0xA1 { Self.reset(&bytes, &bytePlace) } else { break }
            }
            bytes[place] = bytes[newPlace]
            bytes[newPlace] = UInt16(truncatingIfNeeded: symbol)
        }

        mutating func run(_ input: inout LegacyBitInput, _ window: inout LegacyWindow,
                          sink: (UnsafeRawBufferPointer) throws -> Void) throws {
            owed = window.limit - 1
            if owed >= 0 { try nextFlags(&input); flagCount = 8 }
            while owed >= 0 {
                if input.isPastEnd { throw LegacyDecodeError.truncated }
                try window.flush(final: false, sink: sink)
                if literalMode { try literal(&input, &window); continue }
                flagCount -= 1
                if flagCount < 0 { try nextFlags(&input); flagCount = 7 }
                if flags & 0x80 != 0 {
                    flags <<= 1
                    if matchWeight > literalWeight { try longMatch(&input, &window) } else { try literal(&input, &window) }
                } else {
                    flags <<= 1
                    flagCount -= 1
                    if flagCount < 0 { try nextFlags(&input); flagCount = 7 }
                    if flags & 0x80 != 0 {
                        flags <<= 1
                        if matchWeight > literalWeight { try literal(&input, &window) } else { try longMatch(&input, &window) }
                    } else {
                        flags <<= 1
                        try shortMatch(&input, &window)
                    }
                }
            }
        }
    }
}
