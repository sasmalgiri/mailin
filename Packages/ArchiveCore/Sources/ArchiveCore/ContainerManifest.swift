//
//  ContainerManifest.swift
//  ArchiveCore
//
//  Release audit bf1a5b9, R3 and R8 (= OUT-06a).
//
//  R3: an mbox or PST output used to be checked by looking each message's
//  Message-ID up in the WHOLE archive (first matching record wins). Two copies
//  of A then both "matched" A while the selected B was missing, and a message
//  without a Message-ID could not be tied to anything. The export now writes,
//  beside every container it produces, the frozen selection in output order —
//  one line per record with its archive ID, folder and a content fingerprint
//  that does not depend on the Message-ID. Verification consumes those
//  expected occurrences one-to-one (`ExportReconciliation`, manifest route).
//
//  R8: the same file is the writer's durable journal. At every batch boundary
//  the output is flushed to the device first, THEN a checkpoint line records
//  the committed byte offset, the record count, the input positions consumed
//  and the SHA-256 of the file's first `offset` bytes — and the manifest is
//  flushed too. After a drive is pulled mid-export, `recover(output:)` finds
//  the last checkpoint whose prefix hash still verifies, inventories what lies
//  past it (records the receipt never vouched for, the last possibly cut),
//  cuts the file and the manifest back to that boundary and returns the exact
//  resume point. A resume then appends from there, so the receipt, the
//  parseable records and the finished file agree with no record twice.
//
//  Format: JSON lines, append-only, bounded memory on both sides.
//    {"kind":"header","version":1,"format":"mbox","startPosition":0,…}
//    {"kind":"record","ordinal":0,"position":0,"emailID":…,"messageID":…,"folder":…,"fingerprint":…,"offset":…,"length":…}
//    {"kind":"checkpoint","positions":200,"records":200,"bytes":…,"sha256":…}
//    {"kind":"end","positions":…,"records":…,"bytes":…,"sha256":…}
//  The sidecar is `.<output name>.mailin-manifest` in the output's folder — a
//  hidden file, so mail clients importing the folder do not trip over it.
//

import Foundation
import CryptoKit

enum ContainerManifest {

    static let version = 1

    /// The sidecar that belongs to `output`.
    static func url(for output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent("." + output.lastPathComponent + ".mailin-manifest")
    }

    /// Keeps the sidecar with its container when the container is renamed
    /// (the PST part that becomes the file the user named). A missing
    /// sidecar is not an error: there is nothing to move.
    static func moveSidecar(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        // V4: the connected-mail provenance sidecar goes with its container too.
        let provenanceFrom = ConnectedProvenanceSidecar.url(forContainer: source)
        if fm.fileExists(atPath: provenanceFrom.path) {
            let provenanceTo = ConnectedProvenanceSidecar.url(forContainer: destination)
            if fm.fileExists(atPath: provenanceTo.path) { try fm.removeItem(at: provenanceTo) }
            try fm.moveItem(at: provenanceFrom, to: provenanceTo)
        }
        let from = url(for: source), to = url(for: destination)
        guard fm.fileExists(atPath: from.path) else { return }
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try fm.moveItem(at: from, to: to)
    }

    // MARK: - Lines

    struct Line: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case header, record, checkpoint, end }
        var kind: Kind
        // header
        var version: Int? = nil
        var format: String? = nil
        var startPosition: Int? = nil
        var createdAt: String? = nil
        // record
        /// Output order within this file, from 0.
        var ordinal: Int? = nil
        /// The record's position in the export's frozen selection.
        var position: Int? = nil
        var emailID: String? = nil
        var messageID: String? = nil
        /// The folder occurrence the record was written for (its first folder).
        var folder: String? = nil
        /// `ContainerManifest.fingerprint(of:)`; nil when the record was
        /// header-only at export time (located bytes streamed from source).
        var fingerprint: String? = nil
        var offset: UInt64? = nil
        var length: UInt64? = nil
        // checkpoint / end
        var positions: Int? = nil
        var records: Int? = nil
        var bytes: UInt64? = nil
        var sha256: String? = nil
    }

    // MARK: - Content fingerprint (independent of the Message-ID)

    /// SHA-256 over the fields the content check requires to be equal for a
    /// matching pair in every container format, each under the comparison's
    /// own normalisation: subject (unfolded), From/To/Cc addresses, plain and
    /// HTML body text, and the attachment names as a multiset. A pair the
    /// check would call matching therefore always has equal fingerprints; the
    /// converse is never assumed — a paired message is still compared field
    /// by field. Nil for a header-only record (its content is not in hand).
    static func fingerprint(of email: MBOXParser.RawEmail, allowHeaderOnly: Bool = false) -> String? {
        if !allowHeaderOnly, ExportReconciliation.isHeaderOnly(email) { return nil }
        var hash = SHA256()
        func add(_ tag: String, _ value: String) {
            hash.update(data: Data(tag.utf8)); hash.update(data: Data([0x1F]))
            hash.update(data: Data(value.utf8)); hash.update(data: Data([0x1E]))
        }
        let headers = email.headers
        add("subject", ExportReconciliation.header("Subject", headers).map(ExportReconciliation.unfold) ?? "")
        for name in ["From", "To", "Cc"] {
            add(name, ExportReconciliation.header(name, headers).map { ExportReconciliation.addressList(ExportReconciliation.unfold($0)).joined(separator: ",") } ?? "")
        }
        add("plain", ExportReconciliation.text(email.plainBody))
        add("html", ExportReconciliation.text(email.htmlBody))
        add("attachments", email.attachments.map { $0.filename.trimmingCharacters(in: .whitespacesAndNewlines) }.sorted().joined(separator: "\u{1F}"))
        return hex(hash.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Durable flush

    /// `F_FULLFSYNC` (the bytes reach the medium, not only the drive's
    /// cache), falling back to `fsync` where the filesystem refuses it.
    static func fullSync(_ handle: FileHandle) throws {
        let fd = handle.fileDescriptor
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        if fsync(fd) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // MARK: - Writer

    enum ManifestError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let why): return "The export's manifest cannot be used: \(why)." }
        }
    }

    /// Appends lines; record lines are held until the next checkpoint (or
    /// flush) so the manifest never lists a record whose bytes were not
    /// flushed first. Memory: one batch of lines.
    final class Writer {
        let url: URL
        private let handle: FileHandle
        private var buffer = Data()
        /// Records listed in this file so far (written or buffered).
        private(set) var records: Int
        private var durableRecords: Int
        private static let encoder: JSONEncoder = {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
        }()

        /// A fresh manifest for a fresh output (any old sidecar is replaced).
        init(creatingFor output: URL, format: String, startPosition: Int) throws {
            url = ContainerManifest.url(for: output)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            records = 0; durableRecords = 0
            let header = Line(kind: .header, version: ContainerManifest.version, format: format, startPosition: startPosition,
                              createdAt: ISO8601DateFormatter().string(from: Date()))
            try handle.write(contentsOf: Self.encode(header))
            try ContainerManifest.fullSync(handle)
        }

        /// The manifest of a partial output being continued. Nil when the
        /// partial output has no manifest (written before manifests existed):
        /// the resumed file then has none either and its verification says
        /// so. Throws when there is one but its last line is not the
        /// checkpoint the resume starts from.
        init?(resumingFor output: URL, positions: Int, offset: UInt64, sha256: String) throws {
            let url = ContainerManifest.url(for: output)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let scan = try ContainerManifest.scan(url: url)
            guard scan.end == nil else { throw ManifestError.invalid("it records a finished export") }
            guard let last = scan.checkpoints.last, scan.lastLineIsCheckpoint, !scan.tornTail else {
                throw ManifestError.invalid("it does not end at a checkpoint — recover the partial export first")
            }
            guard last.line.positions == positions, last.line.bytes == offset, last.line.sha256 == sha256 else {
                throw ManifestError.invalid("its last checkpoint (\(last.line.positions ?? -1) positions, \(last.line.bytes ?? 0) bytes) is not the resume point (\(positions) positions, \(offset) bytes)")
            }
            self.url = url
            handle = try FileHandle(forWritingTo: url)
            _ = try handle.seekToEnd()
            records = last.line.records ?? 0
            durableRecords = records
        }

        static func encode(_ line: Line) throws -> Data {
            var data = try encoder.encode(line)
            data.append(0x0A)
            return data
        }

        func record(position: Int, email: MBOXParser.RawEmail, folder: String?, offset: UInt64?, length: UInt64?) throws {
            let line = Line(kind: .record, ordinal: records, position: position, emailID: email.id.uuidString,
                            messageID: ExportReconciliation.header("Message-ID", email.headers).map(ExportReconciliation.identifier).flatMap { $0.isEmpty ? nil : $0 },
                            folder: folder, fingerprint: ContainerManifest.fingerprint(of: email), offset: offset, length: length)
            buffer.append(try Self.encode(line))
            records += 1
        }

        /// The output's bytes up to `bytes` are already on the medium; this
        /// writes the batch's record lines and the checkpoint, then flushes.
        func checkpoint(positions: Int, bytes: UInt64, sha256: String) throws {
            buffer.append(try Self.encode(Line(kind: .checkpoint, positions: positions, records: records, bytes: bytes, sha256: sha256)))
            try writeBuffer()
            try ContainerManifest.fullSync(handle)
            durableRecords = records
        }

        /// Record lines without a checkpoint (PST: not resumable, nothing to cut back to).
        func flush() throws {
            try writeBuffer()
            durableRecords = records
        }

        func finish(positions: Int, bytes: UInt64?, sha256: String?) throws {
            buffer.append(try Self.encode(Line(kind: .end, positions: positions, records: records, bytes: bytes, sha256: sha256)))
            try writeBuffer()
            try ContainerManifest.fullSync(handle)
            durableRecords = records
        }

        /// A stop cut the output back to the last checkpoint: lines past it are dropped.
        func discardPending() {
            buffer.removeAll()
            records = durableRecords
        }

        func close() { try? handle.close() }

        func remove() {
            close()
            try? FileManager.default.removeItem(at: url)
        }

        private func writeBuffer() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Reading (streamed)

    /// Calls `body` for every complete, decodable line with the byte offset
    /// just past it. Returns false from `body` to stop. Returns whether the
    /// file ended in a line that could not be read (a torn write).
    @discardableResult
    static func forEachLine(url: URL, _ body: (Line, UInt64) throws -> Bool) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var carry = Data()
        var consumed: UInt64 = 0
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                let lineData = carry[start..<nl]
                guard let line = try? decoder.decode(Line.self, from: lineData) else { return true }
                consumed += UInt64(nl - start + 1)
                start = carry.index(after: nl)
                if try !body(line, consumed) { return false }
            }
            carry = Data(carry[start...])
        }
        return !carry.isEmpty
    }

    struct Checkpoint: Sendable, Equatable {
        let line: Line
        /// Byte offset just past the checkpoint line in the manifest.
        let manifestEnd: UInt64
    }

    struct Scan: Sendable {
        var header: Line?
        var recordLines = 0
        var checkpoints: [Checkpoint] = []
        var end: Line?
        var lastLineIsCheckpoint = false
        var tornTail = false
        /// A checkpoint whose record count disagrees with the lines before it.
        var inconsistent: String?
    }

    /// One pass over the manifest. Memory: one entry per checkpoint (one per
    /// batch), never per record.
    static func scan(url: URL) throws -> Scan {
        var s = Scan()
        s.tornTail = try forEachLine(url: url) { line, end in
            switch line.kind {
            case .header: if s.header == nil { s.header = line }
            case .record: s.recordLines += 1
            case .checkpoint:
                if line.records != s.recordLines, s.inconsistent == nil {
                    s.inconsistent = "a checkpoint counts \(line.records ?? -1) records after \(s.recordLines) record lines"
                }
                s.checkpoints.append(Checkpoint(line: line, manifestEnd: end))
            case .end: s.end = line
            }
            s.lastLineIsCheckpoint = line.kind == .checkpoint
            return true
        }
        return s
    }

    /// Sequential access to the record lines, in output order.
    final class RecordCursor {
        private let handle: FileHandle
        private var carry = Data()
        private var eof = false
        private let decoder = JSONDecoder()

        init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
        deinit { try? handle.close() }

        func next() throws -> Line? {
            while true {
                if let nl = carry.firstIndex(of: 0x0A) {
                    let data = carry[carry.startIndex..<nl]
                    carry = Data(carry[carry.index(after: nl)...])
                    guard let line = try? decoder.decode(Line.self, from: data) else { eof = true; carry.removeAll(); return nil }
                    if line.kind == .record { return line }
                    continue
                }
                if eof { return nil }
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { eof = true; return nil }
                carry.append(chunk)
            }
        }
    }

    // MARK: - R8: recovery to a verified boundary

    struct Recovery: Sendable, Equatable {
        /// Input positions of the selection the boundary vouches for — the
        /// resume's `skipFirst` (cumulative across earlier resumes).
        var positions: Int
        /// Records in the file up to the boundary.
        var records: Int
        /// The boundary's byte offset — the resume's expected length.
        var offset: UInt64
        /// SHA-256 of the file's first `offset` bytes — the resume's expected hash.
        var sha256: String
        /// The file's length when it was found again.
        var bytesFound: UInt64
        /// Bytes past the boundary that were cut away.
        var tailBytes: UInt64
        /// Records that began past the boundary (none was vouched for by a checkpoint).
        var tailRecords: Int
        /// The last of them did not end at a record separator: it was cut.
        var tailLastRecordCut: Bool
        /// Later checkpoints whose prefix hash did not verify (or lay past the end of the file).
        var checkpointsRejected: Int

        var tailCompleteRecords: Int { tailLastRecordCut ? max(0, tailRecords - 1) : tailRecords }

        /// English statement for the receipt (the app localises its own line).
        var summary: String {
            var line = "recovered to a verified boundary: \(records) record(s) at byte \(offset), SHA-256 of the prefix verified"
            if tailBytes > 0 {
                line += "; past it \(tailBytes) byte(s): \(tailCompleteRecords) complete record(s)"
                if tailLastRecordCut { line += " and 1 cut record" }
                line += " the receipt never counted — removed, the resume writes them again"
            }
            if checkpointsRejected > 0 { line += "; \(checkpointsRejected) later checkpoint(s) did not verify and were not used" }
            return line
        }
    }

    enum RecoveryError: LocalizedError, Equatable {
        case noManifest
        case alreadyFinished
        case noVerifiedBoundary(String)
        case manifestInvalid(String)
        var errorDescription: String? {
            switch self {
            case .noManifest: return "The partial export has no manifest, so no boundary can be verified. Start the export again."
            case .alreadyFinished: return "The export finished; there is nothing to recover."
            case .noVerifiedBoundary(let why): return "No verified boundary was found in the partial export (\(why)). Start the export again."
            case .manifestInvalid(let why): return "The partial export's manifest cannot be used (\(why)). Start the export again."
            }
        }
    }

    /// After an interrupted single-file export (drive pulled, process killed):
    /// verify, inventory, cut back, and return the exact resume point.
    static func recover(output: URL) throws -> Recovery {
        let fm = FileManager.default
        let manifestURL = url(for: output)
        guard fm.fileExists(atPath: manifestURL.path), fm.fileExists(atPath: output.path) else { throw RecoveryError.noManifest }
        let s = try scan(url: manifestURL)
        guard s.header?.version == version else { throw RecoveryError.manifestInvalid("no readable header") }
        if s.end != nil { throw RecoveryError.alreadyFinished }
        if let why = s.inconsistent { throw RecoveryError.manifestInvalid(why) }
        let size = (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let candidates = s.checkpoints.filter { ($0.line.bytes ?? .max) <= size && $0.line.sha256 != nil }
        guard !candidates.isEmpty else {
            throw RecoveryError.noVerifiedBoundary(s.checkpoints.isEmpty ? "the run stopped before its first checkpoint" : "the file is shorter than every checkpoint")
        }

        // One forward pass, the running hash snapshotted at each candidate offset.
        let reader = try FileHandle(forReadingFrom: output)
        var digest = SHA256()
        var position: UInt64 = 0
        var verified: Checkpoint? = nil
        var index = 0
        func settle() {
            while index < candidates.count, candidates[index].line.bytes == position {
                let copy = digest
                if hex(copy.finalize()) == candidates[index].line.sha256 { verified = candidates[index] }
                index += 1
            }
        }
        settle()
        let last = candidates.last?.line.bytes ?? 0
        while position < last {
            let next = candidates[index].line.bytes ?? last
            let want = Int(min(UInt64(1 << 20), next - position))
            guard let chunk = try reader.read(upToCount: want), !chunk.isEmpty else { break }
            digest.update(data: chunk)
            position += UInt64(chunk.count)
            settle()
        }
        guard let boundary = verified, let offset = boundary.line.bytes, let sha = boundary.line.sha256 else {
            try? reader.close()
            throw RecoveryError.noVerifiedBoundary("no checkpoint's prefix hash matches the file")
        }
        let rejected = s.checkpoints.count - (s.checkpoints.firstIndex(of: boundary).map { $0 + 1 } ?? s.checkpoints.count)

        // Inventory the tail: record starts ("From " after a blank line, or at
        // the boundary itself, which is a record boundary).
        try reader.seek(toOffset: offset)
        var tailRecords = 0
        var lineLength = 0
        var prefix: [UInt8] = []
        var previousEmpty = true
        var lastBytes: [UInt8] = []
        let from = Array("From ".utf8)
        while let chunk = try autoreleasepool(invoking: { try reader.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    previousEmpty = lineLength == 0 || (lineLength == 1 && prefix.first == 0x0D)
                    lineLength = 0; prefix.removeAll(keepingCapacity: true)
                } else {
                    if lineLength < from.count {
                        prefix.append(byte)
                        if prefix.count == from.count, previousEmpty, prefix == from { tailRecords += 1 }
                    }
                    lineLength += 1
                }
            }
            lastBytes = Array((lastBytes + chunk.suffix(4)).suffix(4))
        }
        try? reader.close()
        let tailBytes = size - offset
        let endsAtSeparator = lastBytes.suffix(2) == [0x0A, 0x0A] || lastBytes == [0x0D, 0x0A, 0x0D, 0x0A]
        let cut = tailBytes > 0 && !endsAtSeparator
        if cut, tailRecords == 0 { tailRecords = 1 }   // cut inside its envelope line

        // Cut the output and the manifest back to the boundary, durably.
        let out = try FileHandle(forWritingTo: output)
        do {
            try out.truncate(atOffset: offset)
            try fullSync(out)
            try out.close()
        } catch { try? out.close(); throw error }
        let m = try FileHandle(forWritingTo: manifestURL)
        do {
            try m.truncate(atOffset: boundary.manifestEnd)
            try fullSync(m)
            try m.close()
        } catch { try? m.close(); throw error }

        return Recovery(positions: boundary.line.positions ?? 0, records: boundary.line.records ?? 0, offset: offset, sha256: sha,
                        bytesFound: size, tailBytes: tailBytes, tailRecords: tailRecords, tailLastRecordCut: cut,
                        checkpointsRejected: rejected)
    }
}

extension ExportWriteOptions {
    /// The write options that continue a recovered partial export exactly at its verified boundary.
    static func resuming(from recovery: ContainerManifest.Recovery) -> ExportWriteOptions {
        ExportWriteOptions(skipFirst: recovery.positions, append: true, keepPartialOnCancel: true,
                           expectedAppendOffset: recovery.offset, expectedAppendSHA256: recovery.sha256)
    }
}

extension ExportRequest {
    /// The app's resume of a recovered partial export: the same request (its
    /// selection fingerprint included), positioned at the verified boundary,
    /// so its `writeOptions` are `ExportWriteOptions.resuming(from:)`.
    func resumed(from recovery: ContainerManifest.Recovery) -> ExportRequest {
        var resume = self
        resume.skipFirst = recovery.positions
        resume.resumeArtifactBytes = recovery.offset
        resume.resumeArtifactSHA256 = recovery.sha256
        return resume
    }
}
