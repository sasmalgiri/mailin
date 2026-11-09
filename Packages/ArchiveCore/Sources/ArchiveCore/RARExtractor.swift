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
//  Audit R6: given a password (the attachment's Unlock…), encrypted members
//  and encrypted headers are opened — the decoder reads the decrypted view
//  of the archive (RARDecryptedArchive.swift). RAR 5.0 says a password is
//  wrong before any data is read (its check value); RAR 3/4 stores no check,
//  so a member that does not decode or whose CRC-32 does not match under the
//  password is "the password did not open it". The password is held only as
//  long as this object.
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
        private let keyring: RARKeyring?
        private var sources: [Int: RandomAccessSource] = [:]
        private lazy var decoder = Decoder(volumePaths: volumes.prefix(decodableVolumeCount).compactMap { $0 })
        /// R6: members in the decrypted view (whole in one present volume), by ordinal → position in the view.
        private lazy var viewMembers: [Member] = archive.members.filter { member in
            member.firstVolume == member.lastVolume && !member.isSplitBefore && !member.isSplitAfter
                && member.firstVolume < volumes.count && volumes[member.firstVolume] != nil
        }
        private lazy var viewIndex: [Int: Int] = Dictionary(uniqueKeysWithValues: viewMembers.enumerated().map { ($1.ordinal, $0) })
        private lazy var decryptedDecoder: Decoder = {
            let format = archive.format, isSolid = archive.isSolid, members = viewMembers
            return Decoder { [unowned self] in
                guard let keyring = self.keyring else { throw ReadError.encryptedHeaders }
                return try RARReader.decryptedStream(format: format, isSolid: isSolid, members: members, keyring: keyring,
                                                     source: { try self.source(forVolume: $0) })
            }
        }()

        /// A single archive, or — when `logicalName` names a volume of a RAR
        /// set (`x.part1.rar …`, `x.rar` + `x.r00 …`) and the archive says it
        /// is one — the whole set from the volumes among `siblings`.
        /// `password` (R6) opens encrypted headers and members; without it
        /// an archive with encrypted headers throws `encryptedHeaders`.
        init(url: URL, logicalName: String? = nil, siblings: [SplitVolumeSet.Sibling] = [], password: String? = nil) throws {
            let keyring = password.map { RARKeyring(password: $0) }
            self.keyring = keyring
            let primary = try RARReader.read(source: try FileRandomAccessSource(url: url), keyring: keyring)
            let name = logicalName ?? url.lastPathComponent
            if primary.isMultiVolume,
               let set = try RARVolumeSet.assemble(primary: url, primaryArchive: primary, primaryName: name, siblings: siblings, keyring: keyring) {
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

        /// The members of `member`'s solid stream decoded before it (empty
        /// outside a solid stream, or for a stored member, which is not in it).
        private func solidPredecessors(of member: Member) -> ArraySlice<Member> {
            guard member.isSolid, member.method != 0, member.ordinal > 0, member.ordinal < archive.members.count else { return [] }
            var start = member.ordinal
            while start > 0 {
                let previous = archive.members[start - 1]
                start -= 1
                if !previous.isSolid && previous.method != 0 && !previous.isDirectory { break }
            }
            return archive.members[start..<member.ordinal]
        }

        /// Needs the password: encrypted itself, or decoded after an encrypted member of its solid stream.
        private func needsPassword(_ member: Member) -> Bool {
            member.isEncrypted || solidPredecessors(of: member).contains { $0.isEncrypted && !$0.isDirectory }
        }

        /// The note for a member that will not be read, known from its headers
        /// alone (nil when it will be read, or is encrypted — that is "locked").
        func refusal(for member: Member) -> String? {
            if let reason = member.unsafePath { return "unsafe path (\(reason)), not opened" }
            if member.isSymlink { return "a symbolic link, not followed" }
            if let gap = missingVolume(for: member) { return "not opened: volume \(gap.number) (\(gap.name)) missing" }
            if member.isSplitBefore || member.isSplitAfter { return "not opened: continues in another volume" }
            if let reason = member.compressionRefusal { return reason }
            if let reason = member.encryptionRefusal { return reason }
            if keyring != nil, needsPassword(member), let reason = viewRefusal(for: member) { return reason }
            return nil
        }

        /// Why the decrypted view cannot serve `member`, or nil.
        private func viewRefusal(for member: Member) -> String? {
            if viewIndex[member.ordinal] == nil { return "an encrypted member split across volumes is not opened" }
            if solidPredecessors(of: member).contains(where: { viewIndex[$0.ordinal] == nil }) {
                return "an encrypted solid stream split across volumes is not opened"
            }
            return nil
        }

        /// Writes `member` to `destination`, verified, or throws the named refusal.
        func extract(_ member: Member, to destination: URL, maxOutputBytes: Int64? = nil, availableDiskBytes: Int64? = nil) throws {
            if let reason = member.unsafePath { throw ReadError.unsafePath(member: member.name, reason: reason) }
            guard !member.isDirectory else { throw ReadError.malformed("\(member.name): is a directory") }
            let locked = needsPassword(member)
            if locked, keyring == nil { throw ReadError.encrypted(member: member.name) }
            if let gap = missingVolume(for: member) { throw SplitVolumeError.volumeMissing(gap.number, expectedName: gap.name) }
            if member.isSplitBefore || member.isSplitAfter {
                throw ReadError.splitAcrossVolumes(member: member.name, detail: member.isSplitBefore ? "continues from the previous volume" : "continues in the next volume")
            }
            if let reason = member.compressionRefusal { throw ReadError.compressionNotOpened(member: member.name, reason: reason) }
            if let reason = member.encryptionRefusal { throw ReadError.compressionNotOpened(member: member.name, reason: reason) }
            if locked {
                try extractDecrypted(member, to: destination, maxOutputBytes: maxOutputBytes, availableDiskBytes: availableDiskBytes)
                return
            }
            if member.method == 0 && member.firstVolume == member.lastVolume {
                try RARReader.extract(member, source: try source(forVolume: member.firstVolume), to: destination,
                                      maxOutputBytes: maxOutputBytes, availableDiskBytes: availableDiskBytes)
                return
            }
            if member.format == .rar4, RARReader.legacyAlgorithmVersions.contains(member.algorithmVersion) {
                try extractLegacy(member, to: destination, maxOutputBytes: maxOutputBytes, availableDiskBytes: availableDiskBytes)
                return
            }
            try decode(member, with: decoder, to: destination, maxOutputBytes: maxOutputBytes, availableDiskBytes: availableDiskBytes)
            // A merged member's own header CRC is the whole file's only in its last part; libarchive checked it.
        }

        /// One libarchive pass writes the member; size and CRC-32 checked. Returns the CRC-32 of what was written.
        @discardableResult
        private func decode(_ member: Member, with decoder: Decoder, to destination: URL, maxOutputBytes: Int64?, availableDiskBytes: Int64?,
                            checkCRC: Bool = true) throws -> UInt32 {
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
            if checkCRC, member.firstVolume == member.lastVolume, let expected = member.crc32, crc != expected {
                throw ReadError.crcMismatch(member: member.name)
            }
            succeeded = true
            return crc
        }

        /// A RAR 1.5 / 2.0 compressed member, decoded by mailin's own decoder
        /// (RARLegacyDecoder.swift) straight from its volume; size and CRC-32 checked.
        private func extractLegacy(_ member: Member, to destination: URL, maxOutputBytes: Int64?, availableDiskBytes: Int64?) throws {
            let available = availableDiskBytes ?? ZIPArchiveReader.freeSpace(at: destination.deletingLastPathComponent())
            if let available, available < member.unpackedSize + diskMarginBytes {
                throw ReadError.insufficientDisk(member: member.name, needed: member.unpackedSize + diskMarginBytes, available: available)
            }
            let volume = try source(forVolume: member.firstVolume)
            guard member.dataOffset >= 0, member.packedSize >= 0, member.dataOffset <= volume.length - member.packedSize else {
                throw ReadError.truncated("\(member.name): data")
            }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let out = try FileHandle(forWritingTo: destination)
            var succeeded = false
            defer {
                try? out.close()
                if !succeeded { try? FileManager.default.removeItem(at: destination) }
            }
            var crc = ZIPArchiveReader.CRC32()
            var written: Int64 = 0
            do {
                try RARReader.decodeLegacy(version: member.algorithmVersion, source: volume, offset: member.dataOffset,
                                           packedSize: member.packedSize, unpackedSize: member.unpackedSize) { chunk in
                    written += Int64(chunk.count)
                    if let maxOutputBytes, written > maxOutputBytes { throw ReadError.budgetExceeded(member: member.name, limit: maxOutputBytes) }
                    let data = Data(chunk)
                    crc.update(data)
                    try out.write(contentsOf: data)
                }
            } catch let error as LegacyDecodeError {
                throw ReadError.decodeFailed(member: member.name, detail: error.description)
            }
            if written != member.unpackedSize {
                throw ReadError.sizeMismatch(member: member.name, declared: member.unpackedSize, actual: written)
            }
            if let expected = member.crc32, crc.value != expected { throw ReadError.crcMismatch(member: member.name) }
            succeeded = true
        }

        /// R6: an encrypted member (or one after an encrypted member of its
        /// solid stream), decoded from the decrypted view.
        private func extractDecrypted(_ member: Member, to destination: URL, maxOutputBytes: Int64?, availableDiskBytes: Int64?) throws {
            guard let keyring else { throw ReadError.encrypted(member: member.name) }
            if let reason = viewRefusal(for: member) { throw ReadError.compressionNotOpened(member: member.name, reason: reason) }
            guard let position = viewIndex[member.ordinal] else { throw ReadError.compressionNotOpened(member: member.name, reason: "not in the decrypted view") }
            // RAR 5.0: the stored check value says "wrong password" before any byte is decoded.
            var keys: RARCrypto.RAR5Keys?
            var passwordConfirmed = false
            if member.isEncrypted, let encryption = member.encryption, encryption.scheme == .rar5, let salt = encryption.salt {
                let derived = keyring.rar5Keys(salt: salt, log2Count: encryption.log2Count)
                keys = derived
                if let check = encryption.passwordCheck {
                    guard check == derived.passwordCheck else { throw ReadError.wrongPassword(member: member.name) }
                    passwordConfirmed = true
                }
            }
            var viewMember = member
            viewMember.ordinal = position
            let mac = member.encryption?.useMAC == true
            let crc: UInt32
            do {
                crc = try decode(viewMember, with: decryptedDecoder, to: destination, maxOutputBytes: maxOutputBytes,
                                 availableDiskBytes: availableDiskBytes, checkCRC: !mac)
            } catch let error as ReadError {
                switch error {
                case .budgetExceeded, .insufficientDisk:
                    throw error
                case .decodeFailed, .crcMismatch, .sizeMismatch, .malformed:
                    // RAR 3/4 has no password check: wrong bytes under a password are the password's.
                    if passwordConfirmed { throw error }
                    throw ReadError.wrongPassword(member: member.name)
                default:
                    throw error
                }
            }
            guard mac, let keys else { return }
            // RAR 5.0 "use MAC": the stored CRC-32 / BLAKE2sp are keyed to the password.
            var matches = true
            if let stored = member.crc32 { matches = RARCrypto.mac(crc: crc, hashKey: keys.hashKey) == stored }
            if matches, let stored = member.blake2 {
                matches = RARCrypto.mac(digest: try RARReader.blake2sp(of: destination), hashKey: keys.hashKey) == stored
            }
            if !matches {
                try? FileManager.default.removeItem(at: destination)
                if passwordConfirmed { throw ReadError.crcMismatch(member: member.name) }
                throw ReadError.wrongPassword(member: member.name)
            }
        }
    }
}
