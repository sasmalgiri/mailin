//
//  Argon2.swift
//  ArchiveCore
//
//  Audit R6 "ODF Argon2id": the memory-hard key derivation LibreOffice 7.x+
//  can use for password-protected OpenDocument files
//  (`manifest:key-derivation-name` …#argon2id with argon2-iterations /
//  argon2-memory / argon2-lanes). Argon2 per RFC 9106 (version 0x13), with
//  BLAKE2b per RFC 7693 inside; Argon2d and Argon2i come with it because the
//  RFC's test vectors for all three check the shared code. Pure Swift, no
//  network, nothing kept: the caller passes the password-derived bytes and
//  gets the tag back.
//
//  Real limit (stated where it is used): memory up to 1 GiB (1,048,576 KiB)
//  and up to 1,000 passes; a file asking for more is reported by name.
//

import Foundation

enum Argon2 {

    enum Variant: UInt32 { case d = 0, i = 1, id = 2 }

    enum Failure: Error, Equatable, LocalizedError {
        case invalid(String)
        case overLimit(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let what): return "Argon2 parameters are invalid: \(what)"
            case .overLimit(let what): return "Argon2 asks for \(what)"
            }
        }
    }

    static let version: UInt32 = 0x13
    static let maxMemoryKiB: UInt32 = 1_048_576
    static let maxPasses: UInt32 = 1_000

    /// The Argon2 tag (RFC 9106 §3.2).
    static func hash(password: [UInt8], salt: [UInt8], secret: [UInt8] = [], associatedData: [UInt8] = [],
                     iterations t: UInt32, memoryKiB m: UInt32, lanes p: UInt32, tagLength: Int,
                     variant: Variant = .id) throws -> [UInt8] {
        guard p >= 1, p <= 0xFF_FFFF else { throw Failure.invalid("\(p) lanes") }
        guard t >= 1 else { throw Failure.invalid("\(t) passes") }
        guard m >= 8 * p else { throw Failure.invalid("\(m) KiB for \(p) lanes") }
        guard tagLength >= 4 else { throw Failure.invalid("\(tagLength)-byte tag") }
        guard salt.count >= 8 else { throw Failure.invalid("\(salt.count)-byte salt") }
        guard m <= maxMemoryKiB else { throw Failure.overLimit("\(m) KiB of memory, over the \(maxMemoryKiB) KiB this reader allows") }
        guard t <= maxPasses else { throw Failure.overLimit("\(t) passes, over the \(maxPasses) this reader allows") }

        // H0
        var h0Input: [UInt8] = []
        for v in [p, UInt32(tagLength), m, t, version, variant.rawValue] { h0Input += le32(v) }
        h0Input += le32(UInt32(password.count)) + password
        h0Input += le32(UInt32(salt.count)) + salt
        h0Input += le32(UInt32(secret.count)) + secret
        h0Input += le32(UInt32(associatedData.count)) + associatedData
        let h0 = BLAKE2b.hash(h0Input, outputLength: 64)

        let lanes = Int(p)
        let segment = Int(m) / (4 * lanes)
        let laneLength = segment * 4
        let blocks = laneLength * lanes
        var memory = [UInt64](repeating: 0, count: blocks * 128)

        for lane in 0..<lanes {
            for column in 0..<2 {
                let bytes = hPrime(h0 + le32(UInt32(column)) + le32(UInt32(lane)), 1024)
                let base = (lane * laneLength + column) * 128
                for k in 0..<128 { memory[base + k] = le64(bytes, 8 * k) }
            }
        }

        var state = FillState()
        for pass in 0..<Int(t) {
            for slice in 0..<4 {
                for lane in 0..<lanes {
                    fillSegment(&memory, state: &state, pass: pass, lane: lane, slice: slice, lanes: lanes,
                                laneLength: laneLength, segment: segment, blocks: blocks, passes: Int(t), variant: variant)
                }
            }
        }

        var final = [UInt64](repeating: 0, count: 128)
        for lane in 0..<lanes {
            let base = (lane * laneLength + laneLength - 1) * 128
            for k in 0..<128 { final[k] ^= memory[base + k] }
        }
        var finalBytes: [UInt8] = []
        finalBytes.reserveCapacity(1024)
        for w in final { finalBytes += le64Bytes(w) }
        return hPrime(finalBytes, tagLength)
    }

    // MARK: - Filling

    private struct FillState {
        var r = [UInt64](repeating: 0, count: 128)
        var q = [UInt64](repeating: 0, count: 128)
        var input = [UInt64](repeating: 0, count: 128)
        var address = [UInt64](repeating: 0, count: 128)
    }

    private static func fillSegment(_ memory: inout [UInt64], state: inout FillState, pass: Int, lane: Int, slice: Int, lanes: Int,
                                    laneLength: Int, segment: Int, blocks: Int, passes: Int, variant: Variant) {
        let dataIndependent = variant == .i || (variant == .id && pass == 0 && slice < 2)
        if dataIndependent {
            for k in 0..<128 { state.input[k] = 0 }
            state.input[0] = UInt64(pass); state.input[1] = UInt64(lane); state.input[2] = UInt64(slice)
            state.input[3] = UInt64(blocks); state.input[4] = UInt64(passes); state.input[5] = UInt64(variant.rawValue)
        }
        let start = (pass == 0 && slice == 0) ? 2 : 0
        if dataIndependent && start == 2 { nextAddresses(&state) }
        var current = lane * laneLength + slice * segment + start
        var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1
        for i in start..<segment {
            if current % laneLength == 1 { previous = current - 1 }
            let pseudo: UInt64
            if dataIndependent {
                if i % 128 == 0 { nextAddresses(&state) }
                pseudo = state.address[i % 128]
            } else {
                pseudo = memory[previous * 128]
            }
            var refLane = Int((pseudo >> 32) % UInt64(lanes))
            if pass == 0 && slice == 0 { refLane = lane }
            let sameLane = refLane == lane
            // Reference area (RFC 9106 §3.4.1.2)
            var area: Int
            if pass == 0 {
                if slice == 0 { area = i - 1 }
                else if sameLane { area = slice * segment + i - 1 }
                else { area = slice * segment + (i == 0 ? -1 : 0) }
            } else {
                if sameLane { area = laneLength - segment + i - 1 }
                else { area = laneLength - segment + (i == 0 ? -1 : 0) }
            }
            let j1 = pseudo & 0xFFFF_FFFF
            let x = (j1 &* j1) >> 32
            let y = (UInt64(area) &* x) >> 32
            let relative = UInt64(area) - 1 - y
            let startPosition = (pass == 0 || slice == 3) ? 0 : (slice + 1) * segment
            let refIndex = (startPosition + Int(relative)) % laneLength
            fillBlock(&memory, state: &state, previous: previous, reference: refLane * laneLength + refIndex, next: current, withXor: pass != 0)
            current += 1
            previous += 1
        }
    }

    /// next = G(previous, reference) (XORed into next after the first pass).
    private static func fillBlock(_ memory: inout [UInt64], state: inout FillState, previous: Int, reference: Int, next: Int, withXor: Bool) {
        let p = previous * 128, r = reference * 128, n = next * 128
        for k in 0..<128 { state.r[k] = memory[r + k] ^ memory[p + k] }
        if withXor { for k in 0..<128 { state.q[k] = state.r[k] ^ memory[n + k] } }
        else { for k in 0..<128 { state.q[k] = state.r[k] } }
        permute(&state.r)
        for k in 0..<128 { memory[n + k] = state.q[k] ^ state.r[k] }
    }

    /// The next block of pseudo-random addresses: G(0, G(0, input)).
    private static func nextAddresses(_ state: inout FillState) {
        state.input[6] &+= 1
        // G(0, X) = P(X) ^ X, applied to the input block, then to its result.
        for k in 0..<128 { state.r[k] = state.input[k]; state.q[k] = state.input[k] }
        permute(&state.r)
        for k in 0..<128 { state.address[k] = state.q[k] ^ state.r[k] }
        for k in 0..<128 { state.r[k] = state.address[k]; state.q[k] = state.address[k] }
        permute(&state.r)
        for k in 0..<128 { state.address[k] = state.q[k] ^ state.r[k] }
    }

    /// P over the eight rows, then the eight columns, of 16-byte registers.
    private static func permute(_ v: inout [UInt64]) {
        for row in 0..<8 {
            let b = row * 16
            round(&v, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        for col in 0..<8 {
            let b = col * 2
            round(&v, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49, b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113)
        }
    }

    @inline(__always)
    private static func round(_ v: inout [UInt64], _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int, _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int,
                              _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(&v, i0, i4, i8, i12); gb(&v, i1, i5, i9, i13); gb(&v, i2, i6, i10, i14); gb(&v, i3, i7, i11, i15)
        gb(&v, i0, i5, i10, i15); gb(&v, i1, i6, i11, i12); gb(&v, i2, i7, i8, i13); gb(&v, i3, i4, i9, i14)
    }

    @inline(__always)
    private static func gb(_ v: inout [UInt64], _ ia: Int, _ ib: Int, _ ic: Int, _ id: Int) {
        var a = v[ia], b = v[ib], c = v[ic], d = v[id]
        a = a &+ b &+ 2 &* (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF); d = rotr(d ^ a, 32)
        c = c &+ d &+ 2 &* (c & 0xFFFF_FFFF) &* (d & 0xFFFF_FFFF); b = rotr(b ^ c, 24)
        a = a &+ b &+ 2 &* (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF); d = rotr(d ^ a, 16)
        c = c &+ d &+ 2 &* (c & 0xFFFF_FFFF) &* (d & 0xFFFF_FFFF); b = rotr(b ^ c, 63)
        v[ia] = a; v[ib] = b; v[ic] = c; v[id] = d
    }

    @inline(__always) static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    // MARK: - H' (variable-length hash, RFC 9106 §3.3)

    static func hPrime(_ x: [UInt8], _ length: Int) -> [UInt8] {
        let input = le32(UInt32(length)) + x
        if length <= 64 { return BLAKE2b.hash(input, outputLength: length) }
        let r = (length + 31) / 32 - 2
        var v = BLAKE2b.hash(input, outputLength: 64)
        var out = Array(v[0..<32])
        if r >= 2 {
            for _ in 2...r {
                v = BLAKE2b.hash(v, outputLength: 64)
                out += v[0..<32]
            }
        }
        out += BLAKE2b.hash(v, outputLength: length - 32 * r)
        return out
    }

    // MARK: - Bytes

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le64Bytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    static func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        return v
    }
}

/// BLAKE2b (RFC 7693), unkeyed, 1–64-byte digests, whole input in memory.
enum BLAKE2b {
    static let iv: [UInt64] = [0x6A09_E667_F3BC_C908, 0xBB67_AE85_84CA_A73B, 0x3C6E_F372_FE94_F82B, 0xA54F_F53A_5F1D_36F1,
                               0x510E_527F_ADE6_82D1, 0x9B05_688C_2B3E_6C1F, 0x1F83_D9AB_FB41_BD6B, 0x5BE0_CD19_137E_2179]
    static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func hash(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        precondition(outputLength >= 1 && outputLength <= 64)
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outputLength)
        var offset = 0
        var counter: UInt64 = 0
        var m = [UInt64](repeating: 0, count: 16)
        repeat {
            let remaining = input.count - offset
            let isLast = remaining <= 128
            let take = isLast ? remaining : 128
            for k in 0..<16 { m[k] = 0 }
            for k in 0..<take { m[k / 8] |= UInt64(input[offset + k]) << (8 * UInt64(k % 8)) }
            counter &+= UInt64(take)
            compress(&h, m, counter, isLast)
            offset += take
            if isLast { break }
        } while true
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for w in h { out += Argon2.le64Bytes(w) }
        return Array(out.prefix(outputLength))
    }

    private static func compress(_ h: inout [UInt64], _ m: [UInt64], _ t: UInt64, _ last: Bool) {
        var v = h + iv
        v[12] ^= t
        if last { v[14] = ~v[14] }
        for round in 0..<12 {
            let s = sigma[round % 10]
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]]); g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]]); g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]]); g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]]); g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for k in 0..<8 { h[k] ^= v[k] ^ v[k + 8] }
    }

    @inline(__always)
    private static func g(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x; v[d] = Argon2.rotr(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]; v[b] = Argon2.rotr(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y; v[d] = Argon2.rotr(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]; v[b] = Argon2.rotr(v[b] ^ v[c], 63)
    }
}
