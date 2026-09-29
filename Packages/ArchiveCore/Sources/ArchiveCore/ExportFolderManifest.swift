//
//  ExportFolderManifest.swift
//  ArchiveCore
//
//  Third review T2/T3 (2026-09-29): a per-file export that stops early and is
//  later resumed needs two things a count cannot give it — proof that the
//  files it already wrote are still there and unchanged, and the INPUT
//  position it stopped at (which differs from the number of files produced
//  whenever a message was skipped or withheld). Both live in a manifest
//  inside the export folder: one JSON line per produced file (relative name,
//  bytes, SHA-256) and one boundary line per reported batch (the input
//  position consumed, the files produced so far, and — fourth review Q3 —
//  the messages withheld and skipped so far, so a resumed run's receipt
//  still tells the whole story).
//
//  The manifest is append-only during a run and cut back to the last
//  boundary when a run stops, exactly like the single-document artifact. A
//  resume requires the manifest, requires its last boundary to be the
//  position the receipt recorded, and re-hashes every listed file before a
//  byte is written. Anything else refuses the resume.
//
//  Fourth review Q4/Q6: the manifest is UNTRUSTED input. Every name is
//  validated (relative, no traversal, resolves inside the folder, not a
//  symlink) before anything is deleted; a manifest that cannot be validated
//  or cut back to its boundary refuses the resume rather than guessing.
//

import Foundation
import CryptoKit

struct ExportFolderManifest {
    static let filename = ".mailin-export-manifest.jsonl"

    struct FileEntry: Codable, Equatable {
        var name: String
        var bytes: Int
        var sha256: String
        /// Q5: true for a file that already existed and was ACCEPTED as
        /// output under "skip existing files" — fingerprinted like a produced
        /// file, but never created or removed by the export.
        var existing: Bool? = nil
    }

    struct Boundary: Codable, Equatable {
        var boundary: Int      // input positions consumed
        var produced: Int      // files produced so far (created + accepted)
        var withheld: Int      // messages withheld so far (Q3)
        var skipped: Int       // messages the renderer skipped so far (Q3)
    }

    /// What a verified manifest says about the run it belongs to.
    struct State: Equatable {
        var positions: Int
        var produced: Int
        var withheld: Int
        var skipped: Int
        var files: [FileEntry]
    }

    let url: URL
    private var handle: FileHandle?
    /// Byte offset of the end of the last boundary line.
    private(set) var boundaryOffset: UInt64 = 0

    init(folder: URL) {
        url = folder.appendingPathComponent(Self.filename)
    }

    // MARK: Writing

    mutating func open(append: Bool) throws {
        let fm = FileManager.default
        if !append || !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        boundaryOffset = try h.seekToEnd()
        handle = h
    }

    mutating func appendFile(name: String, bytes: Int, sha256: String, existing: Bool = false) throws {
        try write(FileEntry(name: name, bytes: bytes, sha256: sha256, existing: existing ? true : nil))
    }

    /// Records a batch boundary; everything up to here is durable.
    mutating func appendBoundary(positions: Int, produced: Int, withheld: Int, skipped: Int) throws {
        try write(Boundary(boundary: positions, produced: produced, withheld: withheld, skipped: skipped))
        try handle?.synchronize()
        boundaryOffset = try handle?.offset() ?? boundaryOffset
    }

    /// A stopped run: cut the manifest back to its last boundary. If the cut
    /// fails the manifest is removed — a manifest that may describe files
    /// that are not there must not be offered for resume (Q6, fail closed).
    mutating func truncateToBoundary() {
        do {
            try handle?.truncate(atOffset: boundaryOffset)
            try handle?.synchronize()
        } catch {
            close()
            remove()
        }
    }

    mutating func close() {
        try? handle?.close()
        handle = nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write<T: Encodable>(_ value: T) throws {
        var line = try JSONEncoder().encode(value)
        line.append(0x0A)
        try handle?.write(contentsOf: line)
    }

    // MARK: Verifying

    /// Reads and verifies the manifest for a resume: the last boundary must
    /// equal `expectedPositions`, and every listed file must exist in `folder`
    /// with the recorded size and SHA-256. Files written after the last
    /// boundary (a stop that could not be cut back) are removed — only after
    /// every name has been validated (Q4) — and the manifest itself is cut
    /// back to that boundary (Q6) so the resumed run appends after it. Throws
    /// `ArchiveExportError.partialManifestInvalid` naming the first problem.
    static func verify(folder: URL, expectedPositions: Int) throws -> State {
        let url = folder.appendingPathComponent(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ArchiveExportError.partialManifestInvalid("no export manifest at \(url.path); the partial folder cannot be continued")
        }
        let data = try Data(contentsOf: url)
        var files: [FileEntry] = []
        var lastBoundary: Boundary?
        var filesAtBoundary = 0
        /// Byte offset just past the newline of the last boundary line.
        var boundaryEnd = 0
        let decoder = JSONDecoder()
        var lineStart = 0
        while lineStart < data.count {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A)
            let line = data[lineStart..<(lineEnd ?? data.count)]
            let next = (lineEnd ?? data.count) + 1
            let torn = lineEnd == nil   // no terminating newline: a write cut short
            if line.isEmpty {
                lineStart = next
                continue
            }
            if let boundary = try? decoder.decode(Boundary.self, from: line) {
                guard !torn else { break }   // a torn boundary never happened
                lastBoundary = boundary
                filesAtBoundary = files.count
                boundaryEnd = next
            } else if let entry = try? decoder.decode(FileEntry.self, from: line) {
                guard !torn else { break }
                files.append(entry)
            } else if torn, lastBoundary != nil {
                // A torn trailing line after a boundary is past the durable
                // point; it is cut away below with everything else after it.
                break
            } else {
                throw ArchiveExportError.partialManifestInvalid("unreadable manifest line: \(String(decoding: line.prefix(80), as: UTF8.self))")
            }
            lineStart = next
        }
        guard let boundary = lastBoundary else {
            throw ArchiveExportError.partialManifestInvalid("the manifest records no completed batch")
        }
        guard boundary.boundary == expectedPositions else {
            throw ArchiveExportError.partialManifestInvalid("the manifest stops at input position \(boundary.boundary) but the receipt recorded \(expectedPositions)")
        }
        guard boundary.produced == filesAtBoundary else {
            throw ArchiveExportError.partialManifestInvalid("the manifest lists \(filesAtBoundary) files but its boundary records \(boundary.produced)")
        }

        // Q4: every name — counted or stray — is validated before ANY
        // filesystem mutation. One bad entry refuses the whole resume.
        let canonicalFolder = ArchiveRelocator.canonicalPath(folder)
        var seenNames: Set<String> = []
        var targets: [URL] = []
        for entry in files {
            guard seenNames.insert(entry.name).inserted else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is listed twice in the manifest")
            }
            targets.append(try validatedTarget(for: entry.name, in: folder, canonicalFolder: canonicalFolder))
        }

        // Files written after the last boundary never counted; remove them —
        // only files this export created (never an accepted existing file),
        // only regular files, only inside the folder.
        for (entry, target) in zip(files[filesAtBoundary...], targets[filesAtBoundary...]) {
            guard entry.existing != true else { continue }
            guard let type = try? fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType else { continue }
            guard type == .typeRegular else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is not a regular file; the partial export cannot be trusted")
            }
            try? fm.removeItem(at: target)
        }

        let counted = Array(files[..<filesAtBoundary])
        for (entry, target) in zip(counted, targets[..<filesAtBoundary]) {
            guard let attributes = try? fm.attributesOfItem(atPath: target.path) else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is missing from the partial export")
            }
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is not a regular file; the partial export cannot be trusted")
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard size == entry.bytes else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is \(size) bytes, the manifest recorded \(entry.bytes)")
            }
            let digest = try ArchiveExportService.sha256(ofFile: target).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256 else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) was changed after the run stopped")
            }
        }

        // Q6: the manifest ends exactly at its last boundary before the run
        // reopens it for append; stale entries must not be counted later.
        if boundaryEnd != data.count {
            do {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.truncate(atOffset: UInt64(boundaryEnd))
                try h.synchronize()
            } catch {
                throw ArchiveExportError.partialManifestInvalid("the manifest could not be cut back to its last boundary: \(error.localizedDescription)")
            }
        }
        return State(positions: boundary.boundary, produced: boundary.produced,
                     withheld: boundary.withheld, skipped: boundary.skipped, files: counted)
    }

    /// Q4: a manifest name is accepted only when it is a relative path with
    /// no empty, `.` or `..` component, resolves (through any symlinked
    /// parent) to a location inside `folder`, and is not itself a symlink.
    static func validatedTarget(for name: String, in folder: URL, canonicalFolder: String) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveExportError.partialManifestInvalid("the manifest names a file outside the export folder: \(name.prefix(80))")
        }
        let target = folder.appendingPathComponent(name)
        // The parent is resolved (aliases, symlinked subfolders, missing
        // tails); the resolved parent must be the folder or inside it.
        let parent = ArchiveRelocator.canonicalPath(target.deletingLastPathComponent())
        guard parent == canonicalFolder || parent.hasPrefix(canonicalFolder + "/") else {
            throw ArchiveExportError.partialManifestInvalid("the manifest names a file outside the export folder: \(name.prefix(80))")
        }
        if let type = try? FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw ArchiveExportError.partialManifestInvalid("\(name.prefix(80)) is a symbolic link; the partial export cannot be trusted")
        }
        return target
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
