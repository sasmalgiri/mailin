//
//  RARExtractor.swift
//  ArchiveCore
//
//  GAP-RAR: one object per RAR archive (or multi-volume set) that the
//  container readers use — the listing (merged across volumes), the note for
//  every member that will not be read, and extraction: a stored member that
//  lies whole in one present volume is copied directly (CRC-32 checked, as
//  before); everything else goes through one libarchive pass (`Decoder`).
//

import Foundation

extension RARReader {

    final class Extractor {
        let archive: Archive
        /// Index = volume number − 1 (one entry for a single archive); nil where a volume is missing.
        let volumes: [URL?]
        /// Expected file name of each volume.
        let volumeNames: [String]
        let isVolumeSet: Bool
        /// Volumes 1…n present without a gap: what the decoder (which reads a set from its start) can use.
        let decodableVolumeCount: Int
        private var sources: [Int: RandomAccessSource] = [:]
        private lazy var decoder = Decoder(volumePaths: volumes.prefix(decodableVolumeCount).compactMap { $0 })

        /// A single archive, or — when `logicalName` names a volume of a RAR
        /// set (`x.part1.rar …`, `x.rar` + `x.r00 …`) and the archive says it
        /// is one — the whole set from the volumes among `siblings`.
        init(url: URL, logicalName: String? = nil, siblings: [SplitVolumeSet.Sibling] = []) throws {
            let primary = try RARReader.read(url: url)
            let name = logicalName ?? url.lastPathComponent
            if primary.isMultiVolume,
               let set = try RARVolumeSet.assemble(primary: url, primaryArchive: primary, primaryName: name, siblings: siblings) {
                archive = set.archive
                volumes = set.volumes
                volumeNames = set.names
                isVolumeSet = true
            } else {
                archive = primary
                volumes = [url]
                volumeNames = [name]
                isVolumeSet = false
            }
            decodableVolumeCount = volumes.firstIndex(where: { $0 == nil }) ?? volumes.count
        }

        private func source(forVolume index: Int) throws -> RandomAccessSource {
            if let s = sources[index] { return s }
            guard index < volumes.count, let url = volumes[index] else { throw ReadError.truncated("volume \(index + 1)") }
            let s = try FileRandomAccessSource(url: url)
            sources[index] = s
            return s
        }

        private func missing(_ index: Int) -> (number: Int, name: String) {
            (index + 1, index < volumeNames.count ? volumeNames[index] : "volume \(index + 1)")
        }

        /// The missing volume `member` needs, when there is one.
        private func missingVolume(for member: Member) -> (number: Int, name: String)? {
            guard isVolumeSet else { return nil }
            // A part before the first one listed, or after the last one listed.
            if member.isSplitBefore {
                if let gap = (0..<member.firstVolume).last(where: { volumes[$0] == nil }) { return missing(gap) }
            }
            if member.isSplitAfter { return missing(member.lastVolume + 1) }
            // Parts merged across a gap.
            if let gap = (member.firstVolume...member.lastVolume).first(where: { volumes[$0] == nil }) { return missing(gap) }
            // The decoder reads the set from volume 1: a member it must decode beyond a gap is out of reach.
            let needsDecoder = member.method != 0 || member.firstVolume != member.lastVolume
            if needsDecoder, member.lastVolume >= decodableVolumeCount { return missing(decodableVolumeCount) }
            return nil
        }

        /// The note for a member that will not be read, known from its headers
        /// alone (nil when it will be read, or is encrypted — that is "locked").
        func refusal(for member: Member) -> String? {
            if let reason = member.unsafePath { return "unsafe path (\(reason)), not opened" }
            if member.isSymlink { return "a symbolic link, not followed" }
            if let gap = missingVolume(for: member) { return "not opened: volume \(gap.number) (\(gap.name)) missing" }
            if member.isSplitBefore || member.isSplitAfter { return "not opened: continues in another volume" }
            if !member.isEncrypted, let reason = member.compressionRefusal { return reason }
            return nil
        }

        /// Writes `member` to `destination`, verified, or throws the named refusal.
        func extract(_ member: Member, to destination: URL, maxOutputBytes: Int64? = nil, availableDiskBytes: Int64? = nil) throws {
            if let reason = member.unsafePath { throw ReadError.unsafePath(member: member.name, reason: reason) }
            guard !member.isDirectory else { throw ReadError.malformed("\(member.name): is a directory") }
            if member.isEncrypted { throw ReadError.encrypted(member: member.name) }
            if let gap = missingVolume(for: member) { throw SplitVolumeError.volumeMissing(gap.number, expectedName: gap.name) }
            if member.isSplitBefore || member.isSplitAfter {
                throw ReadError.splitAcrossVolumes(member: member.name, detail: member.isSplitBefore ? "continues from the previous volume" : "continues in the next volume")
            }
            if member.method == 0 && member.firstVolume == member.lastVolume {
                try RARReader.extract(member, source: try source(forVolume: member.firstVolume), to: destination,
                                      maxOutputBytes: maxOutputBytes, availableDiskBytes: availableDiskBytes)
                return
            }
            if let reason = member.compressionRefusal { throw ReadError.compressionNotOpened(member: member.name, reason: reason) }
            let available = availableDiskBytes ?? ZIPArchiveReader.freeSpace(at: destination.deletingLastPathComponent())
            if let available, member.sizeIsKnown, available < member.unpackedSize + diskMarginBytes {
                throw ReadError.insufficientDisk(member: member.name, needed: member.unpackedSize + diskMarginBytes, available: available)
            }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let out = try FileHandle(forWritingTo: destination)
            var succeeded = false
            defer {
                try? out.close()
                if !succeeded { try? FileManager.default.removeItem(at: destination) }
            }
            let (written, crc) = try decoder.decode(member, to: out, maxOutputBytes: maxOutputBytes)
            if member.sizeIsKnown, written != member.unpackedSize {
                throw ReadError.sizeMismatch(member: member.name, declared: member.unpackedSize, actual: written)
            }
            // A merged member's own header CRC is the whole file's only in its last part; libarchive checked it.
            if member.firstVolume == member.lastVolume, let expected = member.crc32, crc != expected {
                throw ReadError.crcMismatch(member: member.name)
            }
            succeeded = true
        }
    }
}
