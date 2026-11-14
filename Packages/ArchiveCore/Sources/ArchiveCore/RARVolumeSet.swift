//
//  RARVolumeSet.swift
//  ArchiveCore
//
//  GAP-RAR: a multi-volume RAR set — `name.part1.rar, name.part2.rar …`
//  (WinRAR 3+ naming) or `name.rar, name.r00, name.r01 …` (the older
//  naming) — read as one archive. Unlike a 7z or spanned-ZIP set the
//  volumes are not a plain byte split: every volume is a RAR archive of its
//  own, and a member that runs over a boundary appears once per volume
//  (split-after in one, split-before in the next). The header walk reads
//  every present volume and merges those parts back into one member; the
//  libarchive decoder is given the run of volumes from volume 1 up to the
//  first one that is missing. A member that needs a missing volume — it runs
//  into it, or it is compressed and lies beyond it (the decoder reads a set
//  only from its start) — is named with that volume ("not opened: volume N
//  (name) missing"); everything else is read. Nothing is joined on disk.
//

import Foundation

enum RARVolumeSet {
    enum Style: Equatable, Sendable { case partN(width: Int), oldStyle }

    struct Part: Equatable, Sendable {
        let stem: String
        /// 1-based volume number.
        let number: Int
        let style: Style
    }

    /// `x.part3.rar` → (x, 3, partN); `x.rar` → (x, 1, oldStyle); `x.r00` → (x, 2, oldStyle).
    static func part(ofName name: String) -> Part? {
        let base = (name as NSString).lastPathComponent
        let lower = base.lowercased()
        let ext = (lower as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        if ext == "rar" {
            let inner = (stem.lowercased() as NSString).pathExtension
            if inner.hasPrefix("part"), inner.count > 4, let n = Int(inner.dropFirst(4)), n >= 1 {
                return Part(stem: (stem as NSString).deletingPathExtension, number: n, style: .partN(width: inner.count - 4))
            }
            return Part(stem: stem, number: 1, style: .oldStyle)
        }
        // .r00 … .r99, then .s00 … (RAR's own continuation of the old naming).
        if ext.count == 3, let letter = ext.first, let ascii = letter.asciiValue, ascii >= UInt8(ascii: "r"), ascii <= UInt8(ascii: "z"),
           let n = Int(ext.dropFirst()), n >= 0 {
            return Part(stem: stem, number: Int(ascii - UInt8(ascii: "r")) * 100 + n + 2, style: .oldStyle)
        }
        return nil
    }

    static func volumeName(stem: String, number: Int, style: Style) -> String {
        switch style {
        case .partN(let width):
            let digits = String(number)
            return "\(stem).part\(String(repeating: "0", count: max(0, width - digits.count)))\(digits).rar"
        case .oldStyle:
            if number <= 1 { return "\(stem).rar" }
            let index = number - 2
            let letter = Character(UnicodeScalar(UInt8(ascii: "r") + UInt8(min(index / 100, 8))))
            return "\(stem).\(letter)\(String(format: "%02d", index % 100))"
        }
    }

    struct Assembled {
        let archive: RARReader.Archive
        /// Index = volume number − 1; nil where the volume is missing.
        let volumes: [URL?]
        /// Expected file name of every volume, present or not.
        let names: [String]
    }

    /// The set around `primary`, or nil when its name is not a volume name.
    static func assemble(primary: URL, primaryArchive: RARReader.Archive, primaryName: String,
                         siblings: [SplitVolumeSet.Sibling], keyring: RARKeyring? = nil) throws -> Assembled? {
        guard let part = part(ofName: primaryName) else { return nil }
        var byNumber: [Int: URL] = [part.number: primary]
        for sibling in siblings {
            guard let p = Self.part(ofName: sibling.name), p.stem.lowercased() == part.stem.lowercased() else { continue }
            let sameStyle: Bool
            switch (p.style, part.style) {
            case (.partN, .partN), (.oldStyle, .oldStyle): sameStyle = true
            default: sameStyle = false
            }
            if sameStyle, byNumber[p.number] == nil { byNumber[p.number] = sibling.url }
        }
        let highest = byNumber.keys.max() ?? part.number
        var volumes: [URL?] = []
        var parsed: [(volume: Int, archive: RARReader.Archive)] = []
        var number = 1
        while number <= highest {
            if let url = byNumber[number] {
                let archive = url == primary ? primaryArchive : try RARReader.read(source: try FileRandomAccessSource(url: url), keyring: keyring)
                volumes.append(url)
                parsed.append((number - 1, archive))
                let continues = !archive.isLastVolume || (archive.members.last?.isSplitAfter ?? false)
                if !continues { break }   // the set ends here; higher numbers are not part of it
            } else {
                volumes.append(nil)
            }
            number += 1
        }
        // The last present volume says the set goes on: the next one is missing.
        if let last = parsed.last, volumes.count == last.volume + 1,
           !last.archive.isLastVolume || (last.archive.members.last?.isSplitAfter ?? false) {
            volumes.append(nil)
        }
        let names = (1...max(1, volumes.count)).map { volumeName(stem: part.stem, number: $0, style: part.style) }
        return Assembled(archive: merge(parsed), volumes: volumes, names: names)
    }

    /// One logical member per file: a split-before part extends the open
    /// split-after member of the same name from an earlier volume.
    static func merge(_ parsed: [(volume: Int, archive: RARReader.Archive)]) -> RARReader.Archive {
        guard var merged = parsed.first?.archive else { return RARReader.Archive(format: .rar5) }
        merged.members = []
        var damage: String?
        for (volume, archive) in parsed {
            if let d = archive.damage, damage == nil { damage = "volume \(volume + 1): \(d)" }
            for var member in archive.members {
                member.firstVolume = volume
                member.lastVolume = volume
                if member.isSplitBefore, var open = merged.members.last, open.isSplitAfter, open.name == member.name {
                    open.lastVolume = volume
                    open.packedSize += member.packedSize
                    open.isSplitAfter = member.isSplitAfter
                    if member.crc32 != nil { open.crc32 = member.crc32 }
                    merged.members[merged.members.count - 1] = open
                    continue
                }
                member.ordinal = merged.members.count
                merged.members.append(member)
            }
        }
        merged.isLastVolume = parsed.last?.archive.isLastVolume ?? true
        merged.damage = damage
        // The decoding windows count the whole set's stream (a solid set continues across volumes).
        RARReader.assignDecoderWindows(&merged)
        return merged
    }
}
