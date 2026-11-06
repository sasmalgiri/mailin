//
//  ExportInventory.swift
//  ArchiveCore
//
//  Five jobs OUT-07 / OUT-04: a finished folder export keeps a durable,
//  portable inventory — `mailin-export-inventory.json` beside the files —
//  listing every output file with its bytes, SHA-256, the record it came
//  from (email id, Message-ID) and, when the layout followed the archive's
//  folders, the folder path as imported next to the file-system-safe name
//  that was used. Until now the per-file hashes were deleted at the end of
//  a successful run; now they are the record.
//
//  `verify(folder:)` re-reads EVERY listed file (streamed, no sampling) and
//  reports missing, changed and unlisted files, so "were the files written"
//  and "do their bytes still match" are two separate, checkable answers.
//
//  OUT-03 / FOLD-05: `safeRelativeDirectory(forFolderPath:)` turns an
//  imported folder path into directory components that cannot leave the
//  export folder and are legal on APFS/HFS+/FAT, mapping the original name
//  back through the inventory.
//

import CryptoKit
import Foundation

struct ExportInventory: Codable, Sendable, Equatable {
    static let filename = "mailin-export-inventory.json"
    static let currentVersion = 1

    struct File: Codable, Sendable, Equatable {
        /// Path relative to the export folder, "/"-separated.
        let path: String
        let bytes: Int
        let sha256: String
        var emailID: String? = nil
        var messageID: String? = nil
        /// The archive folder the message came from (as imported), when the layout used it.
        var originalFolder: String? = nil
        /// Accepted as output under "skip existing files"; not written by this export.
        var existing: Bool? = nil
    }

    var version: Int = ExportInventory.currentVersion
    var createdAt: Date
    var layout: String
    var written: Int
    var withheld: Int
    var skipped: Int
    var positionsConsumed: Int
    var files: [File]

    /// Files the export itself wrote (not pre-existing ones it accepted).
    var writtenFiles: Int { files.filter { $0.existing != true }.count }

    // MARK: Finalising a manifest

    /// Read the run's manifest and write the inventory beside the files.
    /// Returns the inventory's URL. The caller removes the manifest only
    /// after this succeeds, so a failure leaves the manifest as the record.
    static func finalize(folder: URL, manifestURL: URL, layout: String,
                         written: Int, withheld: Int, skipped: Int, positionsConsumed: Int) throws -> URL {
        let parsed = try parseManifest(at: manifestURL)
        let inventory = ExportInventory(createdAt: Date(), layout: layout, written: written, withheld: withheld,
                                        skipped: skipped, positionsConsumed: positionsConsumed, files: parsed.files)
        return try write(inventory, in: folder)
    }

    /// R06 (handoff 7481852): a run whose files were all written but whose
    /// inventory could not be created left its working manifest behind.
    /// This builds the inventory from that manifest — the files listed up to
    /// its last durable boundary, the counts from that boundary — writes it
    /// beside the files and removes the manifest. Nothing already written is
    /// touched; a manifest that is not the folder's own regular file is refused.
    static func repair(folder: URL, layout: String = "repaired-from-manifest") throws -> URL {
        let manifestURL = folder.appendingPathComponent(ExportFolderManifest.filename)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw ArchiveExportError.partialManifestInvalid("the export manifest is not a regular file")
        }
        let parsed = try parseManifest(at: manifestURL)
        guard let boundary = parsed.lastBoundary else {
            throw ArchiveExportError.partialManifestInvalid("the manifest records no completed batch")
        }
        let files = Array(parsed.files.prefix(parsed.filesAtBoundary))
        let inventory = ExportInventory(createdAt: Date(), layout: layout, written: boundary.produced, withheld: boundary.withheld,
                                        skipped: boundary.skipped, positionsConsumed: boundary.boundary, files: files)
        let url = try write(inventory, in: folder)
        ExportFolderManifest(folder: folder).remove()
        return url
    }

    private struct ParsedManifest {
        var files: [File] = []
        var lastBoundary: ExportFolderManifest.Boundary?
        var filesAtBoundary = 0
    }

    /// The manifest's file lines and its last boundary (a torn final line is ignored).
    private static func parseManifest(at manifestURL: URL) throws -> ParsedManifest {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        var parsed = ParsedManifest()
        var lineStart = 0
        while lineStart < data.count {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A)
            let line = data[lineStart..<(lineEnd ?? data.count)]
            let torn = lineEnd == nil
            lineStart = (lineEnd ?? data.count) + 1
            guard !line.isEmpty, !torn else { continue }
            if let entry = try? decoder.decode(ExportFolderManifest.FileEntry.self, from: line) {
                parsed.files.append(File(path: entry.name, bytes: entry.bytes, sha256: entry.sha256, emailID: entry.emailID,
                                         messageID: entry.messageID, originalFolder: entry.originalFolder, existing: entry.existing))
            } else if let boundary = try? decoder.decode(ExportFolderManifest.Boundary.self, from: line) {
                parsed.lastBoundary = boundary
                parsed.filesAtBoundary = parsed.files.count
            }
        }
        return parsed
    }

    private static func write(_ inventory: ExportInventory, in folder: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = folder.appendingPathComponent(filename)
        try encoder.encode(inventory).write(to: url, options: .atomic)
        return url
    }

    static func load(folder: URL) throws -> ExportInventory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportInventory.self, from: Data(contentsOf: folder.appendingPathComponent(filename)))
    }

    // MARK: Verifying

    struct Verification: Sendable, Equatable {
        var listed: Int
        var present: Int
        var matching: Int
        var missing: [String]
        var changed: [String]
        /// Files in the folder the inventory does not list (the inventory itself and hidden files excepted).
        var unlisted: [String]
        var isClean: Bool { missing.isEmpty && changed.isEmpty && unlisted.isEmpty && matching == listed }
    }

    /// Re-hash every listed file. Full, never sampled.
    static func verify(folder: URL) throws -> Verification {
        let inventory = try load(folder: folder)
        let fm = FileManager.default
        var present = 0, matching = 0
        var missing: [String] = [], changed: [String] = []
        for file in inventory.files {
            let url = folder.appendingPathComponent(file.path)
            guard fm.fileExists(atPath: url.path) else { missing.append(file.path); continue }
            present += 1
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            if size != file.bytes { changed.append(file.path); continue }
            let digest = try sha256(of: url)
            if digest == file.sha256 { matching += 1 } else { changed.append(file.path) }
        }
        var unlisted: [String] = []
        let listed = Set(inventory.files.map(\.path))
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            let base = folder.standardizedFileURL.path
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let path = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if path == filename { continue }
                if !listed.contains(path) { unlisted.append(path) }
            }
        }
        return Verification(listed: inventory.files.count, present: present, matching: matching,
                            missing: missing, changed: changed, unlisted: unlisted.sorted())
    }

    static func sha256(of url: URL, chunkSize: Int = 4 * 1_048_576) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Safe names for the source-folder layout

    /// Characters no file system here accepts in a name, plus the path separators.
    private static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)

    /// One folder component as a directory name: forbidden characters become
    /// "-", surrounding dots and spaces go, "." / ".." and empty names become
    /// "_", and names are cut to 200 characters. Never a path separator, so a
    /// name cannot leave the export folder.
    static func safeComponent(_ component: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in component.unicodeScalars { scalars.append(forbidden.contains(scalar) ? "-" : scalar) }
        var name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty || name == "." || name == ".." { name = "_" }
        if name.count > 200 { name = String(name.prefix(200)) }
        return name
    }

    /// "Top of Personal Folders/Inbox/Clients" → "Top of Personal Folders/Inbox/Clients",
    /// with each component made safe. Empty for an empty path.
    static func safeRelativeDirectory(forFolderPath path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { safeComponent(String($0)) }.joined(separator: "/")
    }
}
