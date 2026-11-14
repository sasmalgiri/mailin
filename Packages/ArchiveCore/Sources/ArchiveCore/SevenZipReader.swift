//
//  SevenZipReader.swift
//  ArchiveCore
//
//  Completion directive 2026-11-07 §6 "Containers": a pure Swift 7z reader.
//  Written from the 7z format description (7zFormat.txt in the 7-Zip
//  source, public domain): signature header, plain or encoded (compressed /
//  encrypted) header, pack / unpack / substreams information, coder folders
//  with bind pairs, file names, attributes and empty streams.
//
//  Coders decoded here: Copy, LZMA, LZMA2 (`LZMADecoder.swift`), BCJ x86,
//  Delta, Deflate (the Compression framework's raw DEFLATE, as the ZIP
//  reader uses) and 7zAES (AES-256-CBC; key = SHA-256 iterated
//  2^NumCyclesPower times over salt + password UTF-16LE + counter, via
//  CryptoKit / CommonCrypto). BZip2, PPMd, BCJ2 and the other branch
//  filters are NAMED per member as "compression method X not opened" —
//  never silent. A wrong password surfaces as `ReadError.wrongPassword`
//  (CRC mismatch or a corrupt stream inside an encrypted folder; the
//  header CRC when the header itself is encrypted).
//
//  Every stage pulls (`ByteStream`), so a solid folder is decoded once,
//  in order, and members are handed off as the caller asks for them; the
//  reader is a session that keeps its place in each folder. Member output
//  streams to a scratch file in 64 KiB pieces under the caller's budget
//  (`budgetExceeded`, like the gzip path), size and CRC-32 verified. The
//  only sizeable allocation is the LZMA dictionary, min(declared, folder
//  size), refused above the run's per-part ceiling with a stated reason
//  so Resume can open it.
//
//  Works over `RandomAccessSource`, so a split set (`.7z.001 …`) reads the
//  same way; a read into a missing volume is `SplitVolumeError.volumeMissing`.
//

import Foundation
import Compression
import CryptoKit

final class SevenZipReader {

    /// Bound into import identities; bump when extraction behaviour changes.
    static let version = 1
    static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    static let diskMarginBytes: Int64 = ZIPArchiveReader.diskMarginBytes
    private static let windowSize = 64 * 1024
    /// 7-Zip itself refuses key schedules above 2^24 iterations.
    static let maxCyclesPower = 24

    static func isSevenZip(head: Data) -> Bool {
        head.count >= 6 && head.prefix(6).elementsEqual(signature)
    }

    struct Member: Sendable, Equatable {
        let name: String
        let size: Int64
        let crc32: UInt32?
        let isDirectory: Bool
        /// An "anti" item marks a deletion in an update archive; it carries no data.
        let isAnti: Bool
        /// Unix symlink (mode 0xA000 in the high attribute word) or a Windows reparse point.
        let isSymlink: Bool
        let isEncrypted: Bool
        /// Coders from the packed bytes outwards: "7zAES + LZMA2 + BCJ x86".
        let method: String
        /// The first coder in the chain this reader cannot decode, named.
        let unsupportedMethod: String?
        /// The folder (solid block) the member's bytes live in; nil for empty files and directories.
        let folderIndex: Int?
        let offsetInFolder: Int64
        let attributes: UInt32?

        var isJunk: Bool {
            let base = (name as NSString).lastPathComponent
            return name.hasPrefix("__MACOSX/") || base == ".DS_Store" || base == "Thumbs.db" || base.hasPrefix("._") || name.hasPrefix(".")
        }

        /// Why the name cannot be used as a child path (absolute, traversal, empty).
        var unsafePath: String? { SevenZipReader.unsafePathReason(name) }
    }

    enum ReadError: Error, CustomStringConvertible, Equatable {
        case notASevenZip
        case truncated(String)
        case malformed(String)
        case unsupportedMethod(String, member: String)
        case encrypted(member: String)
        case wrongPassword(member: String)
        case crcMismatch(member: String)
        case sizeMismatch(member: String, declared: Int64, actual: Int64)
        case insufficientDisk(member: String, needed: Int64, available: Int64)
        /// R05: the caller's byte budget was reached while decoding — stopped there.
        case budgetExceeded(member: String, limit: Int64)
        /// The dictionary the stream needs is over the run's ceiling — stated, resumable.
        case dictionaryOverLimit(member: String, needed: Int64, limit: Int64)
        case unsafePath(member: String, reason: String)

        var description: String {
            switch self {
            case .notASevenZip: return "Not a 7z archive (no 7z signature)."
            case .truncated(let what): return "Archive is truncated: \(what)."
            case .malformed(let what): return "Archive is malformed: \(what)."
            case .unsupportedMethod(let m, let member): return "\(member): compression method \(m) not opened."
            case .encrypted(let member): return "\(member): encrypted; a password is needed."
            case .wrongPassword(let member): return "\(member): the password did not open it."
            case .crcMismatch(let member): return "\(member): CRC-32 does not match — the member is damaged."
            case .sizeMismatch(let member, let declared, let actual): return "\(member): declared \(declared) bytes, produced \(actual) — refused."
            case .insufficientDisk(let member, let needed, let available): return "\(member): needs \(needed) bytes of scratch space, \(available) available."
            case .budgetExceeded(let member, let limit): return "\(member): decompression stopped at the \(limit)-byte budget."
            case .dictionaryOverLimit(let member, let needed, let limit): return "\(member): needs a \(needed)-byte LZMA dictionary, over the \(limit)-byte guard."
            case .unsafePath(let member, let reason): return "\(member): unsafe path (\(reason))."
            }
        }
    }

    // MARK: - Parsed structure

    struct Coder: Equatable {
        let id: [UInt8]
        let numInStreams: Int
        let numOutStreams: Int
        let properties: [UInt8]

        var name: String {
            switch id {
            case [0x00]: return "Copy"
            case [0x21]: return "LZMA2"
            case [0x03, 0x01, 0x01]: return "LZMA"
            case [0x03]: return "Delta"
            case [0x03, 0x03, 0x01, 0x03], [0x04]: return "BCJ x86"
            case [0x03, 0x03, 0x01, 0x1B]: return "BCJ2"
            case [0x03, 0x03, 0x02, 0x05], [0x05]: return "BCJ PowerPC"
            case [0x03, 0x03, 0x04, 0x01], [0x06]: return "BCJ IA-64"
            case [0x03, 0x03, 0x05, 0x01], [0x07]: return "BCJ ARM"
            case [0x03, 0x03, 0x07, 0x01], [0x08]: return "BCJ ARM Thumb"
            case [0x03, 0x03, 0x08, 0x05], [0x09]: return "BCJ SPARC"
            case [0x0A]: return "BCJ ARM64"
            case [0x0B]: return "BCJ RISC-V"
            case [0x03, 0x04, 0x01]: return "PPMd"
            case [0x04, 0x01, 0x08]: return "Deflate"
            case [0x04, 0x01, 0x09]: return "Deflate64"
            case [0x04, 0x02, 0x02]: return "BZip2"
            case [0x04, 0xF7, 0x11, 0x01]: return "Zstandard"
            case [0x04, 0xF7, 0x11, 0x02]: return "Brotli"
            case [0x04, 0xF7, 0x11, 0x04]: return "LZ4"
            case [0x04, 0xF7, 0x11, 0x05]: return "LZ5"
            case [0x04, 0xF7, 0x11, 0x06]: return "Lizard"
            case [0x04, 0xF7, 0x11, 0x07]: return "Fast LZMA2"
            case [0x06, 0xF1, 0x07, 0x01]: return "7zAES"
            default: return "0x" + id.map { String(format: "%02X", $0) }.joined()
            }
        }
        var isAES: Bool { id == [0x06, 0xF1, 0x07, 0x01] }
        var isDecodable: Bool {
            switch id {
            case [0x00], [0x21], [0x03, 0x01, 0x01], [0x03], [0x03, 0x03, 0x01, 0x03], [0x04], [0x04, 0x01, 0x08], [0x06, 0xF1, 0x07, 0x01]:
                return numInStreams == 1 && numOutStreams == 1
            default: return false
            }
        }
    }

    struct Folder: Equatable {
        var coders: [Coder]
        var bindPairs: [(inIndex: Int, outIndex: Int)]
        var packedStreams: [Int]
        var unpackSizes: [UInt64]
        var crc: UInt32?
        var firstPackStreamIndex = 0

        static func == (a: Folder, b: Folder) -> Bool {
            a.coders == b.coders && a.unpackSizes == b.unpackSizes && a.crc == b.crc && a.firstPackStreamIndex == b.firstPackStreamIndex
                && a.packedStreams == b.packedStreams && a.bindPairs.map { [$0.inIndex, $0.outIndex] } == b.bindPairs.map { [$0.inIndex, $0.outIndex] }
        }

        var totalOutStreams: Int { coders.reduce(0) { $0 + $1.numOutStreams } }
        var totalInStreams: Int { coders.reduce(0) { $0 + $1.numInStreams } }
        /// The out stream no bind pair consumes: the folder's output.
        var mainOutIndex: Int? {
            (0..<totalOutStreams).first { o in !bindPairs.contains { $0.outIndex == o } }
        }
        var unpackSize: UInt64 { mainOutIndex.flatMap { $0 < unpackSizes.count ? unpackSizes[$0] : nil } ?? 0 }
        var isEncrypted: Bool { coders.contains { $0.isAES } }
        /// Coders named from the packed bytes outwards.
        var methodDescription: String {
            var names: [String] = []
            var out = mainOutIndex
            var guardCount = 0
            while let o = out, guardCount < 64 {
                guardCount += 1
                guard let (c, inBase) = coderIndex(forOut: o) else { break }
                names.insert(coders[c].name, at: 0)
                if let bp = bindPairs.first(where: { $0.inIndex == inBase }) { out = bp.outIndex } else { out = nil }
            }
            return names.joined(separator: " + ")
        }
        var unsupportedCoder: String? { coders.first { !$0.isDecodable }?.name }

        /// The coder producing out stream `o` and the index of its first in stream.
        func coderIndex(forOut o: Int) -> (Int, Int)? {
            var outBase = 0, inBase = 0
            for (i, c) in coders.enumerated() {
                if o >= outBase && o < outBase + c.numOutStreams { return (i, inBase) }
                outBase += c.numOutStreams; inBase += c.numInStreams
            }
            return nil
        }
    }

    struct StreamsInfo {
        var packPosition: UInt64 = 0
        var packSizes: [UInt64] = []
        var folders: [Folder] = []
        var numUnpackStreams: [Int] = []
        var substreamSizes: [UInt64] = []
        var substreamCRCs: [UInt32?] = []
    }

    private struct FileEntry {
        var name = ""
        var hasStream = true
        var isDirectory = false
        var isAnti = false
        var attributes: UInt32?
    }

    // MARK: - Session state

    let source: RandomAccessSource
    private let password: String?
    private(set) var members: [Member] = []
    private(set) var isHeaderEncrypted = false
    private var streams = StreamsInfo()
    private var keyCache: [String: [UInt8]] = [:]
    private var folderStreams: [Int: (stream: ByteStream, position: Int64)] = [:]
    private let dictionaryLimit: Int64

    /// Opens the archive at `url`.
    convenience init(url: URL, password: String? = nil, dictionaryLimit: Int64 = ExtractionLimits.effective.partBytes) throws {
        try self.init(source: try FileRandomAccessSource(url: url), password: password, dictionaryLimit: dictionaryLimit)
    }

    /// Parses the headers. Throws `encrypted(member: "archive index")` for an
    /// encrypted header without a password, `wrongPassword` with a wrong one.
    init(source: RandomAccessSource, password: String? = nil, dictionaryLimit: Int64 = ExtractionLimits.effective.partBytes) throws {
        self.source = source
        self.password = password
        self.dictionaryLimit = dictionaryLimit
        try parse()
    }

    // MARK: - Signature header

    private func parse() throws {
        let start = try source.read(at: 0, count: 32)
        guard start.count >= 6, Self.isSevenZip(head: start) else { throw ReadError.notASevenZip }
        guard start.count == 32 else { throw ReadError.truncated("signature header") }
        let b = [UInt8](start)
        let startCRC = Self.u32(b, 8)
        guard ZIPArchiveReader.CRC32.checksum(Data(b[12..<32])) == startCRC else { throw ReadError.malformed("start header CRC") }
        let nextOffset = Self.u64(b, 12), nextSize = Self.u64(b, 20), nextCRC = Self.u32(b, 28)
        if nextSize == 0 { members = []; return }   // an empty archive
        guard nextOffset <= UInt64(Int64.max) - 64, nextSize <= UInt64(Int.max) else { throw ReadError.malformed("header position out of range") }
        let headerStart = 32 + Int64(nextOffset)
        guard headerStart >= 32, Int64(nextSize) <= source.length, headerStart <= source.length - Int64(nextSize) else {
            throw ReadError.truncated("the archive index at \(headerStart) (\(nextSize) bytes) lies past the end (\(source.length) bytes)")
        }
        guard Int64(nextSize) <= dictionaryLimit else {
            throw ReadError.malformed("archive index of \(nextSize) bytes, over the \(dictionaryLimit)-byte guard")
        }
        var header = try source.readExactly(at: headerStart, count: Int(nextSize), what: "the archive index")
        guard ZIPArchiveReader.CRC32.checksum(header) == nextCRC else { throw ReadError.malformed("archive index CRC") }

        // An encoded header describes how to decode the real one; a few levels at most.
        var rounds = 0
        while header.first == 0x17 {
            rounds += 1
            guard rounds <= 4 else { throw ReadError.malformed("archive index encoded more than four levels deep") }
            isHeaderEncrypted = true
            var reader = HeaderReader(bytes: [UInt8](header), position: 1)
            let info = try parseStreamsInfo(&reader)
            header = try decodeHeader(info)
        }
        guard header.first == 0x01 else { throw ReadError.malformed("archive index does not begin with a header mark") }
        var reader = HeaderReader(bytes: [UInt8](header), position: 1)
        try parseHeader(&reader)
    }

    /// Decodes an encoded header: one folder, read whole (bounded by the guard).
    private func decodeHeader(_ info: StreamsInfo) throws -> Data {
        guard let folder = info.folders.first else { throw ReadError.malformed("encoded archive index without a folder") }
        let size = folder.unpackSize
        guard size > 0, size <= UInt64(dictionaryLimit) else { throw ReadError.malformed("encoded archive index of \(size) bytes, over the \(dictionaryLimit)-byte guard") }
        isHeaderEncrypted = folder.isEncrypted
        if folder.isEncrypted, password == nil { throw ReadError.encrypted(member: "archive index") }
        let stream: ByteStream
        do { stream = try buildFolderStream(folder, in: info, member: "archive index") }
        catch let error as ReadError { throw error }
        catch { throw folder.isEncrypted ? ReadError.wrongPassword(member: "archive index") : ReadError.malformed("archive index: \(error)") }
        var out = Data()
        do {
            while out.count < Int(size) {
                let chunk = try stream.read(upTo: min(Self.windowSize, Int(size) - out.count))
                guard !chunk.isEmpty else { break }
                out.append(chunk)
            }
        } catch let error as ReadError { throw error }
        catch {
            throw folder.isEncrypted ? ReadError.wrongPassword(member: "archive index") : ReadError.malformed("archive index: \(error)")
        }
        guard out.count == Int(size) else {
            throw folder.isEncrypted ? ReadError.wrongPassword(member: "archive index") : ReadError.truncated("encoded archive index")
        }
        if let crc = folder.crc, ZIPArchiveReader.CRC32.checksum(out) != crc {
            throw folder.isEncrypted ? ReadError.wrongPassword(member: "archive index") : ReadError.malformed("encoded archive index CRC")
        }
        return out
    }

    // MARK: - Header

    private struct HeaderReader {
        let bytes: [UInt8]
        var position: Int
        var remaining: Int { bytes.count - position }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw ReadError.truncated("archive index") }
            let b = bytes[position]; position += 1; return b
        }
        /// 7z's variable-length number: the leading byte's high bits say how many follow.
        mutating func number() throws -> UInt64 {
            let first = try byte()
            var mask: UInt8 = 0x80
            var value: UInt64 = 0
            for i in 0..<8 {
                if first & mask == 0 {
                    let high = UInt64(first & (mask &- 1))
                    value |= high << UInt64(8 * i)
                    return value
                }
                value |= UInt64(try byte()) << UInt64(8 * i)
                mask >>= 1
            }
            return value
        }
        /// A count that must fit the bytes that remain (each item needs at least one).
        mutating func count(_ what: String, perItemBytes: Int = 1) throws -> Int {
            let n = try number()
            guard n <= UInt64(remaining / max(perItemBytes, 1) + 1), n <= UInt64(Int.max / 64) else {
                throw ReadError.malformed("\(what) count \(n) exceeds the index")
            }
            return Int(n)
        }
        mutating func int(_ what: String) throws -> Int {
            let n = try number()
            guard n <= UInt64(Int.max) else { throw ReadError.malformed("\(what) \(n) out of range") }
            return Int(n)
        }
        mutating func u32() throws -> UInt32 {
            let b = try take(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= remaining else { throw ReadError.truncated("archive index") }
            let out = Array(bytes[position..<(position + n)]); position += n; return out
        }
        mutating func skip(_ n: Int) throws { _ = try take(n) }
        mutating func bitVector(_ n: Int) throws -> [Bool] {
            var out: [Bool] = []; out.reserveCapacity(n)
            var mask: UInt8 = 0, current: UInt8 = 0
            for _ in 0..<n {
                if mask == 0 { current = try byte(); mask = 0x80 }
                out.append(current & mask != 0)
                mask >>= 1
            }
            return out
        }
        mutating func definedVector(_ n: Int) throws -> [Bool] {
            let all = try byte()
            if all != 0 { return [Bool](repeating: true, count: n) }
            return try bitVector(n)
        }
        mutating func digests(_ n: Int) throws -> [UInt32?] {
            let defined = try definedVector(n)
            var out: [UInt32?] = []
            for d in defined { out.append(d ? try u32() : nil) }
            return out
        }
    }

    private func parseHeader(_ r: inout HeaderReader) throws {
        var files: [FileEntry] = []
        var sawFiles = false
        loop: while true {
            let id = try r.byte()
            switch id {
            case 0x00: break loop
            case 0x02:   // archive properties
                while true {
                    let type = try r.byte()
                    if type == 0 { break }
                    try r.skip(try r.int("property size"))
                }
            case 0x03:   // additional streams: described, not used
                _ = try parseStreamsInfo(&r)
            case 0x04:
                streams = try parseStreamsInfo(&r)
            case 0x05:
                files = try parseFilesInfo(&r)
                sawFiles = true
            default:
                throw ReadError.malformed("unexpected header property 0x\(String(id, radix: 16))")
            }
        }
        guard sawFiles else { members = []; return }
        try buildMembers(files)
    }

    private func parseStreamsInfo(_ r: inout HeaderReader) throws -> StreamsInfo {
        var info = StreamsInfo()
        var sawSubStreams = false
        loop: while true {
            let id = try r.byte()
            switch id {
            case 0x00: break loop
            case 0x06: try parsePackInfo(&r, into: &info)
            case 0x07: try parseUnpackInfo(&r, into: &info)
            case 0x08: try parseSubStreamsInfo(&r, into: &info); sawSubStreams = true
            default: throw ReadError.malformed("unexpected streams property 0x\(String(id, radix: 16))")
            }
        }
        if !sawSubStreams {
            info.numUnpackStreams = [Int](repeating: 1, count: info.folders.count)
            info.substreamSizes = info.folders.map(\.unpackSize)
            info.substreamCRCs = info.folders.map(\.crc)
        }
        // Pack stream bookkeeping: each folder owns a run of pack streams.
        var next = 0
        for i in info.folders.indices {
            info.folders[i].firstPackStreamIndex = next
            next += info.folders[i].packedStreams.count
        }
        guard next <= info.packSizes.count else { throw ReadError.malformed("folders reference \(next) pack streams, \(info.packSizes.count) declared") }
        return info
    }

    private func parsePackInfo(_ r: inout HeaderReader, into info: inout StreamsInfo) throws {
        info.packPosition = try r.number()
        let n = try r.count("pack stream")
        info.packSizes = [UInt64](repeating: 0, count: n)
        loop: while true {
            let id = try r.byte()
            switch id {
            case 0x00: break loop
            case 0x09: for i in 0..<n { info.packSizes[i] = try r.number() }
            case 0x0A: _ = try r.digests(n)
            default: throw ReadError.malformed("unexpected pack property 0x\(String(id, radix: 16))")
            }
        }
    }

    private func parseUnpackInfo(_ r: inout HeaderReader, into info: inout StreamsInfo) throws {
        guard try r.byte() == 0x0B else { throw ReadError.malformed("folder list expected") }
        let n = try r.count("folder")
        guard try r.byte() == 0 else { throw ReadError.malformed("external folder data is not supported") }
        var folders: [Folder] = []
        for _ in 0..<n { folders.append(try parseFolder(&r)) }
        guard try r.byte() == 0x0C else { throw ReadError.malformed("folder unpack sizes expected") }
        for i in folders.indices {
            var sizes: [UInt64] = []
            for _ in 0..<folders[i].totalOutStreams { sizes.append(try r.number()) }
            folders[i].unpackSizes = sizes
        }
        loop: while true {
            let id = try r.byte()
            switch id {
            case 0x00: break loop
            case 0x0A:
                let crcs = try r.digests(n)
                for i in folders.indices { folders[i].crc = crcs[i] }
            default: throw ReadError.malformed("unexpected folder property 0x\(String(id, radix: 16))")
            }
        }
        info.folders = folders
    }

    private func parseFolder(_ r: inout HeaderReader) throws -> Folder {
        let numCoders = try r.count("coder")
        guard numCoders >= 1, numCoders <= 64 else { throw ReadError.malformed("\(numCoders) coders in one folder") }
        var coders: [Coder] = []
        for _ in 0..<numCoders {
            let flag = try r.byte()
            guard flag & 0x80 == 0 else { throw ReadError.malformed("alternative coder methods are not supported") }
            let id = try r.take(Int(flag & 0x0F))
            var numIn = 1, numOut = 1
            if flag & 0x10 != 0 {
                numIn = try r.int("coder in-streams"); numOut = try r.int("coder out-streams")
                guard numIn >= 1, numIn <= 64, numOut >= 1, numOut <= 64 else { throw ReadError.malformed("coder with \(numIn)/\(numOut) streams") }
            }
            var props: [UInt8] = []
            if flag & 0x20 != 0 { props = try r.take(try r.int("coder property size")) }
            coders.append(Coder(id: id, numInStreams: numIn, numOutStreams: numOut, properties: props))
        }
        let totalOut = coders.reduce(0) { $0 + $1.numOutStreams }
        let totalIn = coders.reduce(0) { $0 + $1.numInStreams }
        let numBindPairs = totalOut - 1
        var bindPairs: [(inIndex: Int, outIndex: Int)] = []
        for _ in 0..<numBindPairs {
            let inIndex = try r.int("bind pair in"), outIndex = try r.int("bind pair out")
            guard inIndex < totalIn, outIndex < totalOut else { throw ReadError.malformed("bind pair out of range") }
            bindPairs.append((inIndex, outIndex))
        }
        let numPacked = totalIn - numBindPairs
        guard numPacked >= 1 else { throw ReadError.malformed("folder without a packed stream") }
        var packed: [Int] = []
        if numPacked == 1 {
            guard let free = (0..<totalIn).first(where: { i in !bindPairs.contains { $0.inIndex == i } }) else {
                throw ReadError.malformed("folder in-streams are all bound")
            }
            packed = [free]
        } else {
            for _ in 0..<numPacked {
                let i = try r.int("packed stream index")
                guard i < totalIn else { throw ReadError.malformed("packed stream index out of range") }
                packed.append(i)
            }
        }
        return Folder(coders: coders, bindPairs: bindPairs, packedStreams: packed, unpackSizes: [], crc: nil)
    }

    private func parseSubStreamsInfo(_ r: inout HeaderReader, into info: inout StreamsInfo) throws {
        let folders = info.folders
        var counts = [Int](repeating: 1, count: folders.count)
        var sizes: [UInt64] = []
        var sawSizes = false
        var id = try r.byte()
        if id == 0x0D {
            for i in folders.indices { counts[i] = try r.count("substream") }
            id = try r.byte()
        }
        if id == 0x09 {
            sawSizes = true
            for (i, folder) in folders.enumerated() where counts[i] > 0 {
                var sum: UInt64 = 0
                for _ in 0..<(counts[i] - 1) {
                    let s = try r.number()
                    let (newSum, overflow) = sum.addingReportingOverflow(s)
                    guard !overflow, newSum <= folder.unpackSize else { throw ReadError.malformed("substream sizes exceed the folder") }
                    sizes.append(s); sum = newSum
                }
                sizes.append(folder.unpackSize - sum)
            }
            id = try r.byte()
        }
        if !sawSizes {
            for (i, folder) in folders.enumerated() where counts[i] > 0 {
                guard counts[i] == 1 else { throw ReadError.malformed("substream sizes missing") }
                sizes.append(folder.unpackSize)
            }
        }
        // Digests: known for a folder with one substream and a folder CRC; the rest are listed.
        var unknownCount = 0
        for (i, folder) in folders.enumerated() where counts[i] > 0 {
            if !(counts[i] == 1 && folder.crc != nil) { unknownCount += counts[i] }
        }
        var listed: [UInt32?] = []
        while id != 0x00 {
            switch id {
            case 0x0A:
                listed = try r.digests(unknownCount)
            default:
                throw ReadError.malformed("unexpected substreams property 0x\(String(id, radix: 16))")
            }
            id = try r.byte()
        }
        var crcs: [UInt32?] = []
        var listedIndex = 0
        for (i, folder) in folders.enumerated() where counts[i] > 0 {
            if counts[i] == 1, let crc = folder.crc {
                crcs.append(crc)
            } else {
                for _ in 0..<counts[i] {
                    crcs.append(listedIndex < listed.count ? listed[listedIndex] : nil)
                    listedIndex += 1
                }
            }
        }
        info.numUnpackStreams = counts
        info.substreamSizes = sizes
        info.substreamCRCs = crcs
    }

    private func parseFilesInfo(_ r: inout HeaderReader) throws -> [FileEntry] {
        let n = try r.count("file")
        var files = [FileEntry](repeating: FileEntry(), count: n)
        var emptyStream = [Bool](repeating: false, count: n)
        var emptyFile: [Bool] = []
        var anti: [Bool] = []
        var numEmpty = 0
        while true {
            let type = try r.number()
            if type == 0 { break }
            let size = try r.int("file property size")
            guard size <= r.remaining else { throw ReadError.truncated("file property") }
            let end = r.position + size
            switch type {
            case 0x0E:
                emptyStream = try r.bitVector(n)
                numEmpty = emptyStream.filter { $0 }.count
            case 0x0F:
                emptyFile = try r.bitVector(numEmpty)
            case 0x10:
                anti = try r.bitVector(numEmpty)
            case 0x11:
                guard try r.byte() == 0 else { throw ReadError.malformed("external file names are not supported") }
                let raw = try r.take(end - r.position)
                var names: [String] = []
                var start = 0
                var i = 0
                while i + 1 < raw.count {
                    if raw[i] == 0 && raw[i + 1] == 0 {
                        names.append(Self.utf16LE(raw[start..<i]))
                        start = i + 2
                    }
                    i += 2
                }
                guard names.count == n else { throw ReadError.malformed("\(names.count) file names for \(n) files") }
                for k in 0..<n { files[k].name = names[k] }
            case 0x15:
                let defined = try r.definedVector(n)
                guard try r.byte() == 0 else { throw ReadError.malformed("external attributes are not supported") }
                for k in 0..<n where defined[k] { files[k].attributes = try r.u32() }
            default:
                break   // times, start positions, dummies: described by size, skipped
            }
            guard r.position <= end else { throw ReadError.malformed("file property overran its size") }
            r.position = end
        }
        var emptyIndex = 0
        for k in 0..<n {
            if emptyStream[k] {
                files[k].hasStream = false
                let isFile = emptyIndex < emptyFile.count ? emptyFile[emptyIndex] : false
                files[k].isDirectory = !isFile
                files[k].isAnti = emptyIndex < anti.count ? anti[emptyIndex] : false
                emptyIndex += 1
            }
            if let attr = files[k].attributes, attr & 0x10 != 0, !files[k].hasStream { files[k].isDirectory = true }
        }
        return files
    }

    private func buildMembers(_ files: [FileEntry]) throws {
        var folderIndex = 0
        var indexInFolder = 0
        var substream = 0
        var offset: Int64 = 0
        var out: [Member] = []
        func advanceToFolderWithStreams() {
            while folderIndex < streams.folders.count, folderIndex < streams.numUnpackStreams.count, streams.numUnpackStreams[folderIndex] == 0 { folderIndex += 1 }
        }
        advanceToFolderWithStreams()
        for file in files {
            let attr = file.attributes
            var isSymlink = false
            if let attr {
                if attr & 0x8000 != 0, (attr >> 16) & 0xF000 == 0xA000 { isSymlink = true }
                if attr & 0x400 != 0 { isSymlink = true }
            }
            if !file.hasStream {
                out.append(Member(name: file.name, size: 0, crc32: nil, isDirectory: file.isDirectory, isAnti: file.isAnti, isSymlink: isSymlink,
                                  isEncrypted: false, method: "", unsupportedMethod: nil, folderIndex: nil, offsetInFolder: 0, attributes: attr))
                continue
            }
            guard folderIndex < streams.folders.count, substream < streams.substreamSizes.count else {
                throw ReadError.malformed("more files than streams")
            }
            let folder = streams.folders[folderIndex]
            let size = streams.substreamSizes[substream]
            guard size <= UInt64(Int64.max) else { throw ReadError.malformed("\(file.name): size out of range") }
            out.append(Member(name: file.name, size: Int64(size), crc32: substream < streams.substreamCRCs.count ? streams.substreamCRCs[substream] : nil,
                              isDirectory: false, isAnti: false, isSymlink: isSymlink, isEncrypted: folder.isEncrypted,
                              method: folder.methodDescription, unsupportedMethod: folder.unsupportedCoder,
                              folderIndex: folderIndex, offsetInFolder: offset, attributes: attr))
            offset += Int64(size)
            substream += 1
            indexInFolder += 1
            if indexInFolder >= streams.numUnpackStreams[folderIndex] {
                folderIndex += 1; indexInFolder = 0; offset = 0
                advanceToFolderWithStreams()
            }
        }
        members = out
    }

    // MARK: - Coder pipeline

    /// The bytes of the source a folder's packed streams occupy (for a split
    /// set: which volumes its members need). Nil for an unknown folder.
    func packedByteRange(forFolder index: Int) -> Range<Int64>? {
        guard index >= 0, index < streams.folders.count else { return nil }
        let folder = streams.folders[index]
        var lower = Int64.max, upper = Int64.min
        for j in 0..<folder.packedStreams.count {
            guard let (offset, length) = try? packStreamOffset(folder.firstPackStreamIndex + j, in: streams) else { continue }
            lower = min(lower, offset); upper = max(upper, offset + length)
        }
        return lower < upper ? lower..<upper : nil
    }

    private func packStreamOffset(_ index: Int, in info: StreamsInfo) throws -> (offset: Int64, length: Int64) {
        guard index < info.packSizes.count else { throw ReadError.malformed("pack stream \(index) not declared") }
        var offset = UInt64(32) &+ info.packPosition
        for i in 0..<index { offset = offset &+ info.packSizes[i] }
        let length = info.packSizes[index]
        guard offset <= UInt64(Int64.max), length <= UInt64(Int64.max), Int64(offset) <= source.length, Int64(length) <= source.length - Int64(offset) else {
            throw ReadError.truncated("packed data at \(offset) (\(length) bytes) lies past the end (\(source.length) bytes)")
        }
        return (Int64(offset), Int64(length))
    }

    /// The folder's main output stream, built from the pack streams outwards.
    private func buildFolderStream(_ folder: Folder, in info: StreamsInfo, member: String) throws -> ByteStream {
        guard let main = folder.mainOutIndex else { throw ReadError.malformed("\(member): folder without an output") }
        var depth = 0
        func stream(forOut o: Int) throws -> ByteStream {
            depth += 1
            guard depth <= 64 else { throw ReadError.malformed("\(member): coder chain loops") }
            guard let (c, inBase) = folder.coderIndex(forOut: o) else { throw ReadError.malformed("\(member): out stream \(o) has no coder") }
            let coder = folder.coders[c]
            guard coder.isDecodable else { throw ReadError.unsupportedMethod(coder.name, member: member) }
            let input: ByteStream
            if let bp = folder.bindPairs.first(where: { $0.inIndex == inBase }) {
                input = try stream(forOut: bp.outIndex)
            } else {
                guard let j = folder.packedStreams.firstIndex(of: inBase) else { throw ReadError.malformed("\(member): in stream \(inBase) is unbound") }
                let (offset, length) = try packStreamOffset(folder.firstPackStreamIndex + j, in: info)
                input = FileRangeStream(source: source, offset: offset, length: length)
            }
            guard o < folder.unpackSizes.count, folder.unpackSizes[o] <= UInt64(Int64.max) else { throw ReadError.malformed("\(member): unpack size missing") }
            let unpackSize = Int64(folder.unpackSizes[o])
            return try makeCoder(coder, input: input, unpackSize: unpackSize, member: member)
        }
        return try stream(forOut: main)
    }

    private func makeCoder(_ coder: Coder, input: ByteStream, unpackSize: Int64, member: String) throws -> ByteStream {
        switch coder.id {
        case [0x00]:
            return LimitedByteStream(input, limit: unpackSize)
        case [0x21]:
            guard coder.properties.count >= 1 else { throw ReadError.malformed("\(member): LZMA2 without its property byte") }
            do { return try LZMA2Decoder(input: input, dictionaryByte: coder.properties[0], unpackSize: unpackSize, dictionaryLimit: dictionaryLimit) }
            catch LZMAError.dictionaryOverLimit(let needed, let limit) { throw ReadError.dictionaryOverLimit(member: member, needed: needed, limit: limit) }
            catch { throw ReadError.malformed("\(member): \(error)") }
        case [0x03, 0x01, 0x01]:
            do {
                let props = try LZMADecoder.Properties(sevenZipProperties: Data(coder.properties))
                return try LZMADecoder(input: input, properties: props, unpackSize: unpackSize, dictionaryLimit: dictionaryLimit)
            } catch LZMAError.dictionaryOverLimit(let needed, let limit) { throw ReadError.dictionaryOverLimit(member: member, needed: needed, limit: limit) }
            catch { throw ReadError.malformed("\(member): \(error)") }
        case [0x03]:
            let distance = Int(coder.properties.first ?? 0) + 1
            return DeltaStream(input: input, distance: distance)
        case [0x03, 0x03, 0x01, 0x03], [0x04]:
            return BCJX86Stream(input: input)
        case [0x04, 0x01, 0x08]:
            return try DeflateStream(input: input, member: member)
        case [0x06, 0xF1, 0x07, 0x01]:
            guard let password else { throw ReadError.encrypted(member: member) }
            let (key, iv) = try aesKeyAndIV(properties: coder.properties, password: password, member: member)
            return AESCBCStream(input: input, key: key, iv: iv)
        default:
            throw ReadError.unsupportedMethod(coder.name, member: member)
        }
    }

    // MARK: 7zAES

    private func aesKeyAndIV(properties p: [UInt8], password: String, member: String) throws -> ([UInt8], [UInt8]) {
        guard let b0 = p.first else { throw ReadError.malformed("\(member): 7zAES without properties") }
        let cyclesPower = Int(b0 & 0x3F)
        var saltSize = 0, ivSize = 0
        var cursor = 1
        if b0 & 0xC0 != 0 {
            guard p.count >= 2 else { throw ReadError.malformed("\(member): 7zAES properties truncated") }
            let b1 = p[1]
            saltSize = Int((b0 >> 7) & 1) + Int(b1 >> 4)
            ivSize = Int((b0 >> 6) & 1) + Int(b1 & 0x0F)
            cursor = 2
        }
        guard p.count >= cursor + saltSize + ivSize else { throw ReadError.malformed("\(member): 7zAES salt/IV truncated") }
        let salt = Array(p[cursor..<(cursor + saltSize)])
        var iv = Array(p[(cursor + saltSize)..<(cursor + saltSize + ivSize)])
        while iv.count < 16 { iv.append(0) }
        iv = Array(iv.prefix(16))
        guard cyclesPower == 0x3F || cyclesPower <= Self.maxCyclesPower else {
            throw ReadError.unsupportedMethod("7zAES with 2^\(cyclesPower) key iterations", member: member)
        }
        let cacheKey = salt.map { String(format: "%02x", $0) }.joined() + ":\(cyclesPower)"
        if let key = keyCache[cacheKey] { return (key, iv) }
        let key = Self.aesKey(password: password, salt: salt, numCyclesPower: cyclesPower)
        keyCache[cacheKey] = key
        return (key, iv)
    }

    /// SHA-256 over (salt + password UTF-16LE + 8-byte counter), 2^numCyclesPower
    /// rounds; 0x3F means the raw bytes are the key.
    static func aesKey(password: String, salt: [UInt8], numCyclesPower: Int) -> [UInt8] {
        let pw = Array(password.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        if numCyclesPower == 0x3F {
            var key = [UInt8](repeating: 0, count: 32)
            let src = salt + pw
            for i in 0..<min(32, src.count) { key[i] = src[i] }
            return key
        }
        var block = salt + pw + [UInt8](repeating: 0, count: 8)
        let counterAt = salt.count + pw.count
        var sha = SHA256()
        let rounds = UInt64(1) << UInt64(numCyclesPower)
        var round: UInt64 = 0
        while round < rounds {
            sha.update(data: block)
            var i = counterAt
            while i < block.count { block[i] &+= 1; if block[i] != 0 { break }; i += 1 }
            round += 1
        }
        return Array(sha.finalize())
    }

    // MARK: - Extraction

    /// Streams `member` into `destination`, verifying size and CRC-32. A
    /// solid folder is decoded once: members in archive order continue from
    /// where the previous one stopped; out of order restarts the folder.
    /// - Parameter maxOutputBytes: R05 — stop at this many bytes with `budgetExceeded`.
    func extract(_ member: Member, to destination: URL, maxOutputBytes: Int64? = nil, availableDiskBytes: Int64? = nil) throws {
        if let reason = member.unsafePath { throw ReadError.unsafePath(member: member.name, reason: reason) }
        guard !member.isDirectory else { throw ReadError.malformed("\(member.name): is a directory") }
        guard let folderIndex = member.folderIndex else {
            FileManager.default.createFile(atPath: destination.path, contents: Data())
            return
        }
        if let unsupported = member.unsupportedMethod { throw ReadError.unsupportedMethod(unsupported, member: member.name) }
        if member.isEncrypted, password == nil { throw ReadError.encrypted(member: member.name) }
        let available = availableDiskBytes ?? ZIPArchiveReader.freeSpace(at: destination.deletingLastPathComponent())
        if let available, available < member.size + Self.diskMarginBytes {
            throw ReadError.insufficientDisk(member: member.name, needed: member.size + Self.diskMarginBytes, available: available)
        }
        guard folderIndex < streams.folders.count else { throw ReadError.malformed("\(member.name): folder missing") }
        let folder = streams.folders[folderIndex]

        let stream: ByteStream
        do {
            stream = try positionedStream(folderIndex: folderIndex, folder: folder, at: member.offsetInFolder, member: member.name)
        } catch {
            folderStreams[folderIndex] = nil
            throw mapped(error, member: member.name, encrypted: folder.isEncrypted)
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination); folderStreams[folderIndex] = nil }
        }
        var crc = ZIPArchiveReader.CRC32()
        var written: Int64 = 0
        do {
            while written < member.size {
                let chunk = try stream.read(upTo: Int(min(Int64(Self.windowSize), member.size - written)))
                guard !chunk.isEmpty else { throw ReadError.sizeMismatch(member: member.name, declared: member.size, actual: written) }
                written += Int64(chunk.count)
                if let maxOutputBytes, written > maxOutputBytes { throw ReadError.budgetExceeded(member: member.name, limit: maxOutputBytes) }
                crc.update(chunk)
                try out.write(contentsOf: chunk)
            }
        } catch {
            throw mapped(error, member: member.name, encrypted: folder.isEncrypted)
        }
        if let expected = member.crc32, crc.value != expected {
            throw folder.isEncrypted ? ReadError.wrongPassword(member: member.name) : ReadError.crcMismatch(member: member.name)
        }
        folderStreams[folderIndex] = (stream, member.offsetInFolder + written)
        succeeded = true
    }

    private func positionedStream(folderIndex: Int, folder: Folder, at offset: Int64, member: String) throws -> ByteStream {
        if let cached = folderStreams[folderIndex], cached.position <= offset {
            if cached.position < offset { try cached.stream.skip(offset - cached.position) }
            return cached.stream
        }
        let stream = try buildFolderStream(folder, in: streams, member: member)
        if offset > 0 { try stream.skip(offset) }
        return stream
    }

    private func mapped(_ error: Error, member: String, encrypted: Bool) -> Error {
        if let e = error as? ReadError { return e }
        if error is SplitVolumeError { return error }
        if encrypted { return ReadError.wrongPassword(member: member) }
        if case LZMAError.truncated = error { return ReadError.truncated("\(member): compressed data") }
        return ReadError.malformed("\(member): \(error)")
    }

    // MARK: - Helpers

    static func unsafePathReason(_ name: String) -> String? {
        if name.isEmpty { return "empty name" }
        if name.hasPrefix("/") || name.hasPrefix("\\") { return "absolute path" }
        if name.count >= 2, name[name.index(after: name.startIndex)] == ":" { return "drive letter" }
        let parts = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if parts.contains("..") { return "parent-directory reference" }
        return nil
    }

    private static func utf16LE(_ bytes: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex { units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }
}

// MARK: - Pull stages

/// `length` bytes of a random-access source from `offset`, read sequentially.
final class FileRangeStream: ByteStream {
    private let source: RandomAccessSource
    private var cursor: Int64
    private var remaining: Int64
    init(source: RandomAccessSource, offset: Int64, length: Int64) {
        self.source = source; cursor = offset; remaining = length
    }
    func read(upTo count: Int) throws -> Data {
        guard remaining > 0, count > 0 else { return Data() }
        let chunk = try source.read(at: cursor, count: Int(min(Int64(count), remaining)))
        cursor += Int64(chunk.count)
        remaining -= Int64(chunk.count)
        return chunk
    }
}

/// AES-CBC decryption, no padding (7zAES pads the packed stream to whole blocks).
final class AESCBCStream: ByteStream {
    private let input: ByteStream
    private let key: [UInt8]
    private var chain: [UInt8]
    /// Ciphertext not yet a whole block, and plaintext not yet handed out.
    private var carry = Data()
    private var plain = Data()
    private var ended = false
    init(input: ByteStream, key: [UInt8], iv: [UInt8]) { self.input = input; self.key = key; chain = iv }

    func read(upTo count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        if plain.isEmpty {
            if ended && carry.isEmpty { return Data() }
            let want = max(16, min(65_536, count + 15 - (count + 15) % 16))
            while carry.count < want && !ended {
                let chunk = try input.read(upTo: want - carry.count)
                if chunk.isEmpty { ended = true } else { carry.append(chunk) }
            }
            let usable = carry.count - carry.count % 16
            if usable == 0 {
                if carry.isEmpty { return Data() }
                throw SevenZipReader.ReadError.malformed("encrypted data is not a whole number of blocks")
            }
            let block = [UInt8](carry.prefix(usable))
            carry = Data(carry.dropFirst(usable))
            plain = Data(try CryptoPrimitives.aesCBC(block, key: key, iv: chain, encrypt: false))
            chain = Array(block.suffix(16))
        }
        // The ByteStream contract: at most `count` bytes.
        let take = min(count, plain.count)
        let out = Data(plain.prefix(take))
        plain = Data(plain.dropFirst(take))
        return out
    }
}

/// The Delta filter: each byte is the sum of itself and the byte `distance` back.
final class DeltaStream: ByteStream {
    private let input: ByteStream
    private let distance: Int
    private var history: [UInt8]
    private var position = 0
    init(input: ByteStream, distance: Int) {
        self.input = input; self.distance = max(1, min(256, distance)); history = [UInt8](repeating: 0, count: self.distance)
    }
    func read(upTo count: Int) throws -> Data {
        var bytes = [UInt8](try input.read(upTo: count))
        for i in bytes.indices {
            bytes[i] &+= history[position]
            history[position] = bytes[i]
            position += 1
            if position == distance { position = 0 }
        }
        return Data(bytes)
    }
}

/// The x86 BCJ filter (branch/call/jump address conversion), decoding
/// direction, after Bra86.c in the LZMA SDK. Works on a rolling buffer: the
/// last four bytes wait for more input, since a call may straddle a read.
final class BCJX86Stream: ByteStream {
    private let input: ByteStream
    private var buffer: [UInt8] = []
    private var ready = Data()
    private var ip: UInt32 = 0
    private var state: UInt32 = 0
    private var ended = false
    init(input: ByteStream) { self.input = input }

    func read(upTo count: Int) throws -> Data {
        while ready.isEmpty && !(ended && buffer.isEmpty) {
            if !ended {
                let chunk = try input.read(upTo: max(count, 65_536))
                if chunk.isEmpty { ended = true } else { buffer.append(contentsOf: chunk) }
            }
            if ended {
                _ = Self.convert(&buffer, ip: ip, state: &state)
                ready.append(contentsOf: buffer)
                ip &+= UInt32(truncatingIfNeeded: buffer.count)
                buffer.removeAll()
            } else {
                let processed = Self.convert(&buffer, ip: ip, state: &state)
                if processed > 0 {
                    ready.append(contentsOf: buffer[0..<processed])
                    buffer.removeFirst(processed)
                    ip &+= UInt32(truncatingIfNeeded: processed)
                }
            }
        }
        let take = min(count, ready.count)
        let out = Data(ready.prefix(take))
        ready = Data(ready.dropFirst(take))
        return out
    }

    private static let maskToAllowed: [Bool] = [true, true, true, false, true, false, false, false]
    private static let maskToBitNumber: [Int] = [0, 1, 2, 2, 3, 3, 3, 3]
    @inline(__always) private static func isMSByte(_ b: UInt8) -> Bool { b == 0 || b == 0xFF }

    /// Converts the buffer in place; returns how many leading bytes are final.
    static func convert(_ data: inout [UInt8], ip startIP: UInt32, state: inout UInt32) -> Int {
        let size = data.count
        var prevMask = state & 0x7
        guard size >= 5 else { return 0 }
        let ip = startIP &+ 5
        var bufferPos: UInt = 0
        var prevPosT: UInt = UInt(0) &- 1
        let limit = UInt(size - 4)
        while true {
            var p = bufferPos
            while p < limit, data[Int(p)] & 0xFE != 0xE8 { p += 1 }
            bufferPos = p
            if p >= limit { break }
            prevPosT = bufferPos &- prevPosT
            if prevPosT > 3 {
                prevMask = 0
            } else {
                prevMask = (prevMask << UInt32(prevPosT - 1)) & 0x7
                if prevMask != 0 {
                    let b = data[Int(p) + 4 - maskToBitNumber[Int(prevMask)]]
                    if !maskToAllowed[Int(prevMask)] || isMSByte(b) {
                        prevPosT = bufferPos
                        prevMask = ((prevMask << 1) & 0x7) | 1
                        bufferPos += 1
                        continue
                    }
                }
            }
            prevPosT = bufferPos
            if isMSByte(data[Int(p) + 4]) {
                var src = UInt32(data[Int(p) + 4]) << 24 | UInt32(data[Int(p) + 3]) << 16 | UInt32(data[Int(p) + 2]) << 8 | UInt32(data[Int(p) + 1])
                var dest: UInt32
                while true {
                    dest = src &- (ip &+ UInt32(truncatingIfNeeded: bufferPos))
                    if prevMask == 0 { break }
                    let index = maskToBitNumber[Int(prevMask)] * 8
                    let b = UInt8(truncatingIfNeeded: dest >> UInt32(24 - index))
                    if !isMSByte(b) { break }
                    src = dest ^ ((UInt32(1) << UInt32(32 - index)) &- 1)
                }
                data[Int(p) + 4] = ~UInt8(truncatingIfNeeded: ((dest >> 24) & 1) &- 1)
                data[Int(p) + 3] = UInt8(truncatingIfNeeded: dest >> 16)
                data[Int(p) + 2] = UInt8(truncatingIfNeeded: dest >> 8)
                data[Int(p) + 1] = UInt8(truncatingIfNeeded: dest)
                bufferPos += 5
            } else {
                prevMask = ((prevMask << 1) & 0x7) | 1
                bufferPos += 1
            }
        }
        prevPosT = bufferPos &- prevPosT
        state = prevPosT > 3 ? 0 : ((prevMask << UInt32(prevPosT - 1)) & 0x7)
        return Int(bufferPos)
    }
}

/// Raw DEFLATE through a `compression_stream`, pulled piece by piece.
///
/// §3-P2 SAFETY: the only pointer code in the 7z path, the same shape as
/// `ZIPArchiveReader.inflate`. `source` and `output` are each `windowSize`
/// bytes; a chunk read is at most `windowSize` so `copyBytes` stays inside
/// `source`; the decoder writes at most `dst_size` ≤ `windowSize` bytes into
/// `output`. All three allocations are freed in `deinit`.
final class DeflateStream: ByteStream {
    private static let windowSize = 64 * 1024
    private let input: ByteStream
    private let member: String
    private let streamPointer: UnsafeMutablePointer<compression_stream>
    private let source: UnsafeMutablePointer<UInt8>
    private let output: UnsafeMutablePointer<UInt8>
    private var inputEnded = false
    private var finished = false

    init(input: ByteStream, member: String) throws {
        self.input = input
        self.member = member
        streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard unsafe compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            unsafe streamPointer.deallocate()
            throw SevenZipReader.ReadError.malformed("\(member): deflate decoder could not start")
        }
        source = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.windowSize)
        output = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.windowSize)
        unsafe streamPointer.pointee.src_size = 0
    }

    deinit {
        unsafe compression_stream_destroy(streamPointer)
        unsafe streamPointer.deallocate()
        unsafe source.deallocate()
        unsafe output.deallocate()
    }

    func read(upTo count: Int) throws -> Data {
        guard !finished, count > 0 else { return Data() }
        let want = min(count, Self.windowSize)
        var produced = 0
        while produced == 0 && !finished {
            if unsafe streamPointer.pointee.src_size == 0, !inputEnded {
                let chunk = try input.read(upTo: Self.windowSize)
                if chunk.isEmpty {
                    inputEnded = true
                } else {
                    unsafe chunk.copyBytes(to: source, count: chunk.count)
                    unsafe streamPointer.pointee.src_ptr = UnsafePointer(source)
                    unsafe streamPointer.pointee.src_size = chunk.count
                }
            }
            let flags = inputEnded ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            unsafe streamPointer.pointee.dst_ptr = output
            unsafe streamPointer.pointee.dst_size = want
            let status = unsafe compression_stream_process(streamPointer, flags)
            produced = want - (unsafe streamPointer.pointee.dst_size)
            if status == COMPRESSION_STATUS_ERROR { throw SevenZipReader.ReadError.malformed("\(member): deflate stream is corrupt") }
            if status == COMPRESSION_STATUS_END { finished = true }
            if status == COMPRESSION_STATUS_OK, inputEnded, unsafe streamPointer.pointee.src_size == 0, produced == 0 {
                throw SevenZipReader.ReadError.truncated("\(member): deflate stream ended early")
            }
        }
        return produced > 0 ? unsafe Data(bytes: output, count: produced) : Data()
    }
}
