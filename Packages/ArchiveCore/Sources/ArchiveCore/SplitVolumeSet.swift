//
//  SplitVolumeSet.swift
//  ArchiveCore
//
//  Completion directive 2026-11-07 §6 "Containers": archives split into
//  volumes — ZIP spanned sets (`name.z01 … name.zNN` + `name.zip`, the
//  central directory in the last volume, each entry recording the disk it
//  starts on) and 7z split sets (`name.7z.001, .002 …`, a plain byte split).
//
//  The readers work over `RandomAccessSource`, a flat byte address space;
//  `VolumeSetSource` lays the volumes end to end so a member that runs over
//  a volume boundary is read without the reader knowing. A volume that is
//  not among the sibling files is a hole: every read that touches it throws
//  `SplitVolumeError.volumeMissing(n)`, which the container readers turn
//  into the per-member note "not opened: volume N missing" — the rest of
//  the set is still read. Nothing is copied or joined on disk.
//
//  Volume sizes: present volumes are measured; a missing volume is assumed
//  to be as long as the first present volume, which is how 7-Zip, Info-ZIP
//  and WinZip write sets (equal volumes, a shorter last one). For 7z the
//  start header gives the archive's exact length, so the number of volumes
//  — and which are missing — is known even when the tail is absent.
//

import Foundation

/// A flat, seekable byte source. Single files and volume sets alike.
protocol RandomAccessSource: AnyObject {
    var length: Int64 { get }
    /// Up to `count` bytes at `offset` (short only at the end of the source).
    func read(at offset: Int64, count: Int) throws -> Data
    /// Where volume `disk` (0-based) begins in the flat space; nil when the
    /// set does not have that many volumes. 0 for a single file.
    func diskBase(_ disk: Int) -> Int64?
    /// True when volume `disk` is not available (a hole in the set).
    func isDiskMissing(_ disk: Int) -> Bool
    var volumeCount: Int { get }
}

extension RandomAccessSource {
    /// Exactly `count` bytes or a `SplitVolumeError.truncated`.
    func readExactly(at offset: Int64, count: Int, what: String) throws -> Data {
        let data = try read(at: offset, count: count)
        guard data.count == count else { throw SplitVolumeError.truncated(what) }
        return data
    }
}

enum SplitVolumeError: Error, CustomStringConvertible, Equatable {
    /// 1-based volume number and the file name the set expects for it.
    case volumeMissing(Int, expectedName: String)
    case truncated(String)

    var description: String {
        switch self {
        case .volumeMissing(let n, let name): return "not opened: volume \(n) (\(name)) missing"
        case .truncated(let what): return "the archive ends early: \(what)"
        }
    }
}

/// One file.
final class FileRandomAccessSource: RandomAccessSource {
    private let handle: FileHandle
    let length: Int64
    let volumeCount = 1

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        length = Int64(try handle.seekToEnd())
    }
    deinit { try? handle.close() }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < length, count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
    func diskBase(_ disk: Int) -> Int64? { disk == 0 ? 0 : nil }
    func isDiskMissing(_ disk: Int) -> Bool { false }
}

/// Volumes laid end to end, with holes for the ones that are absent.
final class VolumeSetSource: RandomAccessSource {
    struct Volume {
        let expectedName: String
        let url: URL?
        let size: Int64
        var isMissing: Bool { url == nil }
    }

    private(set) var volumes: [Volume]
    private var handles: [Int: FileHandle] = [:]
    private var bases: [Int64] = []
    let length: Int64

    /// - Parameter volumes: in order; a missing one has no URL and an assumed size.
    init(volumes: [Volume]) {
        self.volumes = volumes
        var running: Int64 = 0
        for v in volumes { bases.append(running); running += v.size }
        length = running
    }
    deinit { for h in handles.values { try? h.close() } }

    var volumeCount: Int { volumes.count }
    func diskBase(_ disk: Int) -> Int64? { disk >= 0 && disk < volumes.count ? bases[disk] : nil }
    func isDiskMissing(_ disk: Int) -> Bool { disk < 0 || disk >= volumes.count || volumes[disk].isMissing }
    var missingVolumeNumbers: [Int] { volumes.indices.filter { volumes[$0].isMissing }.map { $0 + 1 } }

    /// The volume (0-based) holding flat `offset`.
    func disk(containing offset: Int64) -> Int? {
        guard offset >= 0, offset < length else { return nil }
        var lo = 0, hi = volumes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if bases[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The 1-based numbers of the volumes a byte range touches that are missing.
    func missingVolumes(in range: Range<Int64>) -> [Int] {
        guard !range.isEmpty else { return [] }
        var result: [Int] = []
        for (i, v) in volumes.enumerated() where v.isMissing {
            let start = bases[i], end = start + v.size
            if start < range.upperBound && end > range.lowerBound { result.append(i + 1) }
        }
        return result
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < length, count > 0 else { return Data() }
        var out = Data()
        var cursor = offset
        var remaining = Int64(count)
        while remaining > 0, cursor < length, let d = disk(containing: cursor) {
            let v = volumes[d]
            guard let url = v.url else { throw SplitVolumeError.volumeMissing(d + 1, expectedName: v.expectedName) }
            let within = cursor - bases[d]
            let take = Int(min(remaining, v.size - within))
            guard take > 0 else { break }
            let handle: FileHandle
            if let h = handles[d] { handle = h } else { handle = try FileHandle(forReadingFrom: url); handles[d] = handle }
            try handle.seek(toOffset: UInt64(within))
            let chunk = try handle.read(upToCount: take) ?? Data()
            guard !chunk.isEmpty else { break }
            out.append(chunk)
            cursor += Int64(chunk.count)
            remaining -= Int64(chunk.count)
        }
        return out
    }
}

/// Recognises volume names and assembles a set from sibling files.
enum SplitVolumeSet {
    struct Sibling: Sendable, Equatable {
        let name: String
        let url: URL
        init(name: String, url: URL) { self.name = name; self.url = url }
        init(url: URL) { self.name = url.lastPathComponent; self.url = url }
    }

    enum Kind: Sendable, Equatable { case zipSpanned, sevenZipSplit }

    /// What a name says about its place in a set.
    struct Part: Equatable {
        let kind: Kind
        /// The set's stem: "archive" for archive.z01 / archive.zip; "archive.7z" for archive.7z.001.
        let stem: String
        /// 1-based volume number; nil for the ".zip" last volume (its number is the set's count).
        let number: Int?
    }

    /// `archive.z01` → zipSpanned #1; `archive.zip` → zipSpanned last; `archive.7z.001` → sevenZipSplit #1.
    static func part(ofName name: String) -> Part? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        if ext == "zip" { return Part(kind: .zipSpanned, stem: stem, number: nil) }
        if ext.count == 3, ext.hasPrefix("z"), let n = Int(ext.dropFirst()), n >= 1 {
            return Part(kind: .zipSpanned, stem: stem, number: n)
        }
        if ext.count == 3, let n = Int(ext), n >= 1, (stem.lowercased() as NSString).pathExtension == "7z" {
            return Part(kind: .sevenZipSplit, stem: stem, number: n)
        }
        return nil
    }

    static func zipVolumeName(stem: String, number: Int, count: Int) -> String {
        number == count ? "\(stem).zip" : "\(stem).z\(String(format: "%02d", number))"
    }
    static func sevenZipVolumeName(stem: String, number: Int) -> String {
        "\(stem).\(String(format: "%03d", number))"
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Files in the same directory as `url` (import sources).
    static func directorySiblings(of url: URL) -> [Sibling] {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.map { Sibling(name: $0, url: dir.appendingPathComponent($0)) }
    }

    // MARK: 7z

    /// A 7z split set around `primary`, or nil when the name is not a volume.
    /// `archiveLength` (32 + next header offset + size, from the start
    /// header of volume 1) fixes the number of volumes; without it the
    /// highest sibling number does.
    static func sevenZipSet(primary: URL, primaryName: String, siblings: [Sibling]) -> VolumeSetSource? {
        guard let part = part(ofName: primaryName), part.kind == .sevenZipSplit else { return nil }
        var byNumber: [Int: URL] = [:]
        for s in siblings {
            if let p = Self.part(ofName: s.name), p.kind == .sevenZipSplit, p.stem.lowercased() == part.stem.lowercased(), let n = p.number {
                byNumber[n] = s.url
            }
        }
        if let n = part.number { byNumber[n] = primary }
        let firstSize = byNumber[1].map(fileSize) ?? byNumber.keys.sorted().compactMap { byNumber[$0] }.first.map(fileSize) ?? 0
        var count = byNumber.keys.max() ?? 1
        // The start header of volume 1 names the archive's length → exact volume count.
        if let first = byNumber[1], firstSize >= 32, let head = try? FileHandle(forReadingFrom: first).read(upToCount: 32), head.count == 32,
           head.prefix(6).elementsEqual([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            let b = [UInt8](head)
            func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << UInt64(8 * $1) } }
            let total = UInt64(32) &+ u64(12) &+ u64(20)
            if total > 32, total < UInt64(Int64.max), firstSize > 0 {
                let needed = Int((Int64(total) + firstSize - 1) / firstSize)
                count = max(count, needed)
                // Trailing siblings beyond the computed count are not part of this set.
            }
        }
        var volumes: [VolumeSetSource.Volume] = []
        for n in 1...max(count, 1) {
            let name = sevenZipVolumeName(stem: part.stem, number: n)
            if let url = byNumber[n] { volumes.append(.init(expectedName: name, url: url, size: fileSize(url))) }
            else { volumes.append(.init(expectedName: name, url: nil, size: firstSize)) }
        }
        return VolumeSetSource(volumes: volumes)
    }

    // MARK: ZIP

    /// A ZIP spanned set around `primary` (a `.zNN` volume, or a `.zip` whose
    /// end-of-central-directory record says it is disk N > 0). Nil when the
    /// file is an ordinary single ZIP.
    static func zipSet(primary: URL, primaryName: String, siblings: [Sibling]) -> VolumeSetSource? {
        guard let part = part(ofName: primaryName), part.kind == .zipSpanned else { return nil }
        var byNumber: [Int: URL] = [:]
        var last: URL?
        for s in siblings {
            if let p = Self.part(ofName: s.name), p.kind == .zipSpanned, p.stem.lowercased() == part.stem.lowercased() {
                if let n = p.number { byNumber[n] = s.url } else { last = s.url }
            }
        }
        if let n = part.number { byNumber[n] = primary } else { last = primary }
        // The last volume's EOCD: "number of this disk" = count − 1.
        var count: Int?
        if let last, let disks = ZIPArchiveReader.spannedDiskCount(url: last) { count = disks }
        if count == nil {
            // No readable last volume: a .zNN alone, or the .zip is missing.
            guard part.number != nil || last == nil else { return nil }
            count = max((byNumber.keys.max() ?? 0) + 1, 2)
        }
        guard let total = count, total >= 2 else { return nil }   // an ordinary ZIP
        let presentSizes = byNumber.keys.sorted().compactMap { byNumber[$0] }.map(fileSize)
        let assumed = presentSizes.first ?? 0
        var volumes: [VolumeSetSource.Volume] = []
        for n in 1...total {
            let name = zipVolumeName(stem: part.stem, number: n, count: total)
            if n == total {
                if let last { volumes.append(.init(expectedName: name, url: last, size: fileSize(last))) }
                else { volumes.append(.init(expectedName: name, url: nil, size: assumed)) }
            } else if let url = byNumber[n] {
                volumes.append(.init(expectedName: name, url: url, size: fileSize(url)))
            } else {
                volumes.append(.init(expectedName: name, url: nil, size: assumed))
            }
        }
        return VolumeSetSource(volumes: volumes)
    }
}
