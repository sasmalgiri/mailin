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
//  Fifth review S1/S2: the manifest FILE is untrusted too. It is opened by
//  descriptor without following symlinks, must be a plain regular file with
//  one link, and every read, truncate and append goes through a descriptor
//  that was checked that way. Committed output is verified BEFORE any stray
//  file is removed; a stray that cannot be removed refuses the resume and
//  keeps its entry, so the next attempt sees it again.
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

    // MARK: Opening without following symlinks (S1)

    /// Opens `url` with `O_NOFOLLOW` and confirms through the descriptor that
    /// it is a regular file with a single link. A symlink at the path fails
    /// to open (ELOOP); anything that is not a plain file is refused. Every
    /// manifest read or write in this type goes through a handle from here.
    private static func openNoFollow(_ url: URL, flags: Int32) throws -> FileHandle {
        let fd = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let why = errno == ELOOP ? "it is a symbolic link" : String(cString: strerror(errno))
            throw ArchiveExportError.partialManifestInvalid("the export manifest cannot be opened: \(why)")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            throw ArchiveExportError.partialManifestInvalid("the export manifest cannot be inspected")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw ArchiveExportError.partialManifestInvalid("the export manifest is not a regular file")
        }
        guard st.st_nlink == 1 else {
            Darwin.close(fd)
            throw ArchiveExportError.partialManifestInvalid("the export manifest has \(st.st_nlink) links; it must be the folder's own file")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// True when something (file, symlink, anything) sits at `url`.
    private static func entryExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// Sixth review U2: removes the control path with `unlink(2)` — which
    /// removes a regular file or the symlink itself and can never remove a
    /// directory or its contents — and throws for anything but "already
    /// gone". No type check followed by a recursive delete, so a type swap
    /// between the two cannot widen what is removed.
    private static func unlinkControlFile(at url: URL) throws {
        guard unlink(url.path) != 0 else { return }
        if errno == ENOENT { return }
        let why = (errno == EPERM || errno == EISDIR)
            ? "a directory (or something that is not a file) sits at the manifest path"
            : String(cString: strerror(errno))
        throw ArchiveExportError.partialManifestInvalid("the export folder's control path \(filename) could not be claimed: \(why)")
    }

    // MARK: Writing

    mutating func open(append: Bool) throws {
        if append {
            handle = try Self.openNoFollow(url, flags: O_WRONLY)
        } else {
            // A fresh run claims the path: a stale regular file or a symlink
            // (removed as the link itself) is unlinked; a directory or any
            // other object refuses the export rather than being removed. The
            // manifest is then created exclusively so nothing can be
            // substituted in between.
            try Self.unlinkControlFile(at: url)
            handle = try Self.openNoFollow(url, flags: O_WRONLY | O_CREAT | O_EXCL)
        }
        boundaryOffset = try handle?.seekToEnd() ?? 0
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

    /// A stopped run whose past-boundary files were all removed: cut the
    /// manifest back to its last boundary. If the cut fails the manifest is
    /// removed — a manifest that may describe files that are not there must
    /// not be offered for resume (Q6, fail closed).
    mutating func truncateToBoundary() {
        do {
            try handle?.truncate(atOffset: boundaryOffset)
            try handle?.synchronize()
        } catch {
            close()
            remove()
        }
    }

    /// Flush what is written so far without cutting anything (S2: entries
    /// past the boundary stay when their files could not be removed).
    func synchronize() {
        try? handle?.synchronize()
    }

    mutating func close() {
        try? handle?.close()
        handle = nil
    }

    /// Removes the manifest file itself — never a directory at its path (U2).
    func remove() {
        _ = unlink(url.path)
    }

    private func write<T: Encodable>(_ value: T) throws {
        var line = try JSONEncoder().encode(value)
        line.append(0x0A)
        try handle?.write(contentsOf: line)
    }

    // MARK: Verifying

    /// Reads and verifies the manifest for a resume: the last boundary must
    /// equal `expectedPositions`, and every listed file must exist in `folder`
    /// with the recorded size and SHA-256. Only then are files written after
    /// the last boundary (a stop that could not be cut back) removed — every
    /// name validated first (Q4), every removal required to succeed (S2) —
    /// and the manifest cut back to that boundary (Q6) so the resumed run
    /// appends after it. Throws `ArchiveExportError.partialManifestInvalid`
    /// naming the first problem; nothing is mutated before the committed
    /// output has been verified.
    static func verify(folder: URL, expectedPositions: Int) throws -> State {
        let url = folder.appendingPathComponent(filename)
        let fm = FileManager.default
        guard entryExists(at: url) else {
            throw ArchiveExportError.partialManifestInvalid("no export manifest at \(url.path); the partial folder cannot be continued")
        }
        // S1: one descriptor, checked to be the folder's own regular file,
        // used for the read and for the cut-back below.
        let manifest = try openNoFollow(url, flags: O_RDWR)
        defer { try? manifest.close() }
        let data = try manifest.readToEnd() ?? Data()
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

        // S2: the committed output is verified BEFORE anything destructive.
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

        // Files written after the last boundary never counted; remove them —
        // only files this export created (never an accepted existing file),
        // only regular files, only inside the folder. A file that is gone is
        // fine; one that cannot be inspected or removed refuses the resume
        // and keeps its entry for the next attempt (S2).
        for (entry, target) in zip(files[filesAtBoundary...], targets[filesAtBoundary...]) {
            guard entry.existing != true else { continue }
            var st = stat()
            if lstat(target.path, &st) != 0 {
                if errno == ENOENT { continue }
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) could not be inspected: \(String(cString: strerror(errno)))")
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is not a regular file; the partial export cannot be trusted")
            }
            do {
                try fm.removeItem(at: target)
            } catch {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) was written after the last checkpoint and could not be removed: \(error.localizedDescription)")
            }
        }

        // Q6: the manifest ends exactly at its last boundary before the run
        // reopens it for append; stale entries must not be counted later.
        // Through the descriptor checked above, never through the path (S1).
        if boundaryEnd != data.count {
            do {
                try manifest.truncate(atOffset: UInt64(boundaryEnd))
                try manifest.synchronize()
            } catch {
                throw ArchiveExportError.partialManifestInvalid("the manifest could not be cut back to its last boundary: \(error.localizedDescription)")
            }
        }
        return State(positions: boundary.boundary, produced: boundary.produced,
                     withheld: boundary.withheld, skipped: boundary.skipped, files: counted)
    }

    /// Q4: a manifest name is accepted only when it is a relative path with
    /// no empty, `.` or `..` component, is not the control file itself (S1),
    /// resolves (through any symlinked parent) to a location inside
    /// `folder`, and is not itself a symlink.
    static func validatedTarget(for name: String, in folder: URL, canonicalFolder: String) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveExportError.partialManifestInvalid("the manifest names a file outside the export folder: \(name.prefix(80))")
        }
        guard components.last.map(String.init) != filename else {
            throw ArchiveExportError.partialManifestInvalid("the manifest lists its own control file as output")
        }
        let target = folder.appendingPathComponent(name)
        // The parent is resolved (aliases, symlinked subfolders, missing
        // tails); the resolved parent must be the folder or inside it.
        let parent = ArchiveRelocator.canonicalPath(target.deletingLastPathComponent())
        guard parent == canonicalFolder || parent.hasPrefix(canonicalFolder + "/") else {
            throw ArchiveExportError.partialManifestInvalid("the manifest names a file outside the export folder: \(name.prefix(80))")
        }
        var st = stat()
        if lstat(target.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw ArchiveExportError.partialManifestInvalid("\(name.prefix(80)) is a symbolic link; the partial export cannot be trusted")
        }
        return target
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
