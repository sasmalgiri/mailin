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
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        var files: [File] = []
        var lineStart = 0
        while lineStart < data.count {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.count
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            guard !line.isEmpty else { continue }
            if let entry = try? decoder.decode(ExportFolderManifest.FileEntry.self, from: line) {
                files.append(File(path: entry.name, bytes: entry.bytes, sha256: entry.sha256, emailID: entry.emailID,
                                  messageID: entry.messageID, originalFolder: entry.originalFolder, existing: entry.existing))
            }
            // Boundary lines carry no file; they are the manifest's own bookkeeping.
        }
        let inventory = ExportInventory(createdAt: Date(), layout: layout, written: written, withheld: withheld,
                                        skipped: skipped, positionsConsumed: positionsConsumed, files: files)
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
