//
//  ArchiveRelocator.swift
//  maxmailin
//
//  B5: move an existing archive to another volume, safely and verifiably.
//
//  Sequence: refuse unless the destination's verdict is usable and its free
//  space covers the archive with margin → flush the store's WAL and close
//  idle index shards → copy `sqlite/` (database + blob tier) and `fts5/`
//  file by file with progress → verify every file's byte count, the
//  SHA-256 of `emails.db`, and that the copy opens and reports the same row
//  count → write the relocation record and the location → tell the user to
//  relaunch. The copy on this Mac is NEVER removed by the relocator: the
//  user deletes it from the location screen once the new location has been
//  seen working. A destination that is detached later makes the app fall
//  back to that copy, with a banner, instead of showing an empty archive.
//

import Foundation
import os.log

private let relocationLog = Logger(subsystem: "com.ecosanskriti.mailin", category: "ArchiveRelocator")

struct RelocationPlan: Equatable, Sendable {
    var sourceRoot: URL
    var destinationRoot: URL
    var archiveBytes: Int64
    var freeBytes: Int64
    var verdict: ArchiveLocationVerdict
    var fileCount: Int

    /// 10 % margin plus the OS's own comfort margin.
    var requiredBytes: Int64 { archiveBytes + archiveBytes / 10 + StoragePlanner.comfortMargin(volumeCapacityBytes: freeBytes) }
    var canProceed: Bool { verdict.isUsable && freeBytes >= requiredBytes && archiveBytes > 0 }
    var refusalReason: String? {
        if !verdict.isUsable { return verdict.message ?? "That location cannot hold the archive." }
        if archiveBytes == 0 { return "There is no archive to move yet." }
        if freeBytes < requiredBytes {
            return "Not enough space there: the archive needs about \(ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) is free."
        }
        return nil
    }
}

struct RelocationReceipt: Codable, Equatable, Sendable {
    var record: RelocationRecord
    var filesCopied: Int
    var seconds: Double
    var verifiedRows: Int

    var summary: String {
        "Copied \(filesCopied) files, \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)), \(verifiedRows) messages verified in \(String(format: "%.0f", seconds)) s. Quit and relaunch mailin to use the new location."
    }
}

enum RelocationError: LocalizedError {
    case refused(String)
    case verificationFailed(String)
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .refused(let why): return why
        case .verificationFailed(let why): return "The copy did not verify: \(why). Nothing was changed; the archive is still where it was."
        case .sourceMissing: return "The archive to move could not be found."
        }
    }
}

enum ArchiveRelocator {

    /// What a move to `destinationVolume` would involve. `sourceRoot` defaults
    /// to the running archive's root.
    static func plan(sourceRoot: URL = ArchiveLayout.productionRoot, destinationVolume: URL) -> RelocationPlan {
        let sqlite = ArchiveLayout.sqliteDirectory(under: sourceRoot)
        let fts = ArchiveLayout.ftsDirectory(under: sourceRoot)
        let (bytes, files) = measure([sqlite, fts])
        let values = try? destinationVolume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        return RelocationPlan(sourceRoot: sourceRoot,
                              destinationRoot: destinationVolume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true),
                              archiveBytes: bytes,
                              freeBytes: free,
                              verdict: ArchiveLocationPolicy.verdict(for: destinationVolume),
                              fileCount: files)
    }

    /// Perform the move described by `plan`. `store`/`fts` are the LIVE
    /// instances over the source, used to flush and to read the row count the
    /// copy must match. Progress is (bytesCopied, totalBytes).
    static func perform(_ plan: RelocationPlan,
                        store: SQLiteEmailStore,
                        fts: FTSSearchIndex,
                        recordStore: RelocationRecordStore = .production,
                        locationStore: ArchiveLocationStore = ArchiveLocationStore(url: ArchiveLocationStore.productionURL),
                        progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> RelocationReceipt {
        if let why = plan.refusalReason { throw RelocationError.refused(why) }
        let fm = FileManager.default
        let sourceSQLite = ArchiveLayout.sqliteDirectory(under: plan.sourceRoot)
        let sourceFTS = ArchiveLayout.ftsDirectory(under: plan.sourceRoot)
        guard fm.fileExists(atPath: sourceSQLite.appendingPathComponent("emails.db").path) else {
            throw RelocationError.sourceMissing
        }

        // Quiesce: WAL into the main file, idle shards closed, so the copy is
        // a set of self-contained files.
        try await store.checkpoint()
        _ = await fts.sweepIdleShards(ttl: .zero)
        let liveRows = try await store.totalCount()

        let clock = ContinuousClock()
        let start = clock.now
        let destinationSQLite = ArchiveLayout.sqliteDirectory(under: plan.destinationRoot)
        let destinationFTS = ArchiveLayout.ftsDirectory(under: plan.destinationRoot)
        // A stale partial copy from an earlier attempt is replaced, never merged.
        if fm.fileExists(atPath: plan.destinationRoot.path) { try fm.removeItem(at: plan.destinationRoot) }
        try fm.createDirectory(at: plan.destinationRoot, withIntermediateDirectories: true)

        var copied: Int64 = 0
        var files = 0
        let total = plan.archiveBytes
        for (from, to) in [(sourceSQLite, destinationSQLite), (sourceFTS, destinationFTS)] {
            guard fm.fileExists(atPath: from.path) else { continue }
            try copyTree(from: from, to: to) { bytes in
                copied += bytes
                files += 1
                progress?(copied, total)
            }
        }

        // Verify: byte counts per file, the database hash, and a real open.
        try verifyTree(source: sourceSQLite, destination: destinationSQLite)
        if fm.fileExists(atPath: sourceFTS.path) { try verifyTree(source: sourceFTS, destination: destinationFTS) }
        let sourceHash = try ArchiveExportService.sha256(ofFile: sourceSQLite.appendingPathComponent("emails.db"))
        let copyHash = try ArchiveExportService.sha256(ofFile: destinationSQLite.appendingPathComponent("emails.db"))
        guard sourceHash == copyHash else {
            try? fm.removeItem(at: plan.destinationRoot)
            throw RelocationError.verificationFailed("emails.db hash differs")
        }
        let copyStore = SQLiteEmailStore(directory: destinationSQLite)
        let copyRows = try await copyStore.totalCount()
        guard copyRows == liveRows else {
            try? fm.removeItem(at: plan.destinationRoot)
            throw RelocationError.verificationFailed("row count \(copyRows) ≠ \(liveRows)")
        }

        let hex = sourceHash.map { String(format: "%02x", $0) }.joined()
        let record = RelocationRecord(sourceRoot: plan.sourceRoot.path,
                                      destinationRoot: plan.destinationRoot.path,
                                      verifiedAt: Date(),
                                      rows: copyRows,
                                      bytes: copied,
                                      emailsDBSHA256: hex)
        try recordStore.save(record)
        let volume = plan.destinationRoot.deletingLastPathComponent()
        locationStore.save(ArchiveLocation(path: volume.path,
                                           bookmark: ArchiveLocationStore.bookmark(for: volume),
                                           recordedAt: Date()))
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        relocationLog.notice("archive relocated to \(plan.destinationRoot.path, privacy: .public): \(files) files, \(copied) bytes, \(copyRows) rows verified")
        return RelocationReceipt(record: record, filesCopied: files, seconds: seconds, verifiedRows: copyRows)
    }

    /// The copy left on this Mac after a move, if any: what "Delete the copy
    /// on this Mac" removes. Only offered when the relocated archive is the
    /// one in use, so deleting it can never remove the only copy.
    static func retiredCopyOnThisMac(defaultRoot: URL = ArchiveLayout.defaultRoot,
                                     record: RelocationRecord? = RelocationRecordStore.production.load()) -> URL? {
        guard let record, ArchiveLayout.hasArchive(at: record.destinationURL),
              ArchiveLayout.hasArchive(at: defaultRoot),
              record.sourceURL.standardizedFileURL.path == defaultRoot.standardizedFileURL.path else { return nil }
        return defaultRoot
    }

    static func deleteRetiredCopy(defaultRoot: URL = ArchiveLayout.defaultRoot) throws {
        guard let root = retiredCopyOnThisMac(defaultRoot: defaultRoot) else { return }
        for folder in [ArchiveLayout.sqliteFolder, ArchiveLayout.ftsFolder] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        relocationLog.notice("deleted the retired archive copy under \(root.path, privacy: .public)")
    }

    // MARK: Helpers

    static func measure(_ roots: [URL]) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0, files = 0
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                bytes += Int64(values?.fileSize ?? 0)
                files += 1
            }
        }
        return (bytes, files)
    }

    /// File-by-file copy so progress is real and a failure names the file.
    private static func copyTree(from: URL, to: URL, perFile: (Int64) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(at: from, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return }
        for case let item as URL in walker {
            let relative = item.path.dropFirst(from.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = to.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: item, to: target)
                perFile(Int64(values.fileSize ?? 0))
            }
        }
    }

    private static func verifyTree(source: URL, destination: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return }
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values.isDirectory != true else { continue }
            let relative = item.path.dropFirst(source.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = destination.appendingPathComponent(relative)
            let copied = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let copied, copied == values.fileSize else {
                throw RelocationError.verificationFailed("\(relative) is \(copied.map(String.init) ?? "missing"), expected \(values.fileSize ?? -1) bytes")
            }
        }
    }
}
