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
//  position consumed and the files produced so far).
//
//  The manifest is append-only during a run and cut back to the last
//  boundary when a run stops, exactly like the single-document artifact. A
//  resume requires the manifest, requires its last boundary to be the
//  position the receipt recorded, and re-hashes every listed file before a
//  byte is written. Anything else refuses the resume.
//

import Foundation
import CryptoKit

struct ExportFolderManifest {
    static let filename = ".mailin-export-manifest.jsonl"

    struct FileEntry: Codable, Equatable {
        var name: String
        var bytes: Int
        var sha256: String
    }

    struct Boundary: Codable, Equatable {
        var boundary: Int      // input positions consumed
        var produced: Int      // files produced so far
    }

    /// What a verified manifest says about the run it belongs to.
    struct State: Equatable {
        var positions: Int
        var produced: Int
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

    mutating func appendFile(name: String, bytes: Int, sha256: String) throws {
        try write(FileEntry(name: name, bytes: bytes, sha256: sha256))
    }

    /// Records a batch boundary; everything up to here is durable.
    mutating func appendBoundary(positions: Int, produced: Int) throws {
        try write(Boundary(boundary: positions, produced: produced))
        try handle?.synchronize()
        boundaryOffset = try handle?.offset() ?? boundaryOffset
    }

    /// A stopped run: cut the manifest back to its last boundary.
    mutating func truncateToBoundary() {
        try? handle?.truncate(atOffset: boundaryOffset)
        try? handle?.synchronize()
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
    /// with the recorded size and SHA-256. Files past the last boundary (a
    /// stop that could not be cut back) are removed. Throws
    /// `ArchiveExportError.partialManifestInvalid` naming the first problem.
    static func verify(folder: URL, expectedPositions: Int) throws -> State {
        let url = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveExportError.partialManifestInvalid("no export manifest at \(url.path); the partial folder cannot be continued")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var files: [FileEntry] = []
        var lastBoundary: Boundary?
        var filesAtBoundary = 0
        let decoder = JSONDecoder()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(rawLine.utf8)
            if let boundary = try? decoder.decode(Boundary.self, from: data) {
                lastBoundary = boundary
                filesAtBoundary = files.count
            } else if let entry = try? decoder.decode(FileEntry.self, from: data) {
                files.append(entry)
            } else {
                throw ArchiveExportError.partialManifestInvalid("unreadable manifest line: \(rawLine.prefix(80))")
            }
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
        // Files written after the last boundary never counted; remove them.
        for stray in files[filesAtBoundary...] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(stray.name))
        }
        let counted = Array(files[..<filesAtBoundary])
        for entry in counted {
            let path = folder.appendingPathComponent(entry.name)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is missing from the partial export")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? -1
            guard size == entry.bytes else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) is \(size) bytes, the manifest recorded \(entry.bytes)")
            }
            let digest = try ArchiveExportService.sha256(ofFile: path).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256 else {
                throw ArchiveExportError.partialManifestInvalid("\(entry.name) was changed after the run stopped")
            }
        }
        return State(positions: boundary.boundary, produced: boundary.produced, files: counted)
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
