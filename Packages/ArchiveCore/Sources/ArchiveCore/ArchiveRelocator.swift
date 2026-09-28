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
//  Audit F01 (2026-09-28): the relocator must never be able to remove the
//  archive it is moving, or anyone else's. Three rules follow:
//   1. A destination that is the source, or inside it, or contains it, is
//      refused at plan time — by canonical path, so a symlink alias or a
//      re-chosen volume cannot slip past.
//   2. A destination that already holds a mailin archive is refused; only a
//      folder without `emails.db` (a stale partial copy) may be replaced.
//      The copy is made into a staging folder beside the destination and
//      renamed into place only after it verifies, so nothing at the final
//      path is ever removed before a verified replacement exists.
//   3. The copy on this Mac is offered for deletion only once the running
//      store has actually opened at the new root — after the relaunch.
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
    var canProceed: Bool { refusalReason == nil }
    var refusalReason: String? {
        if let conflict = pathConflict { return conflict }
        if !verdict.isUsable { return verdict.message ?? "That location cannot hold the archive." }
        if archiveBytes == 0 { return "There is no archive to move yet." }
        if destinationHoldsArchive {
            return "A mailin archive already exists at \(destinationRoot.path). Choose a folder that does not contain one; mailin never replaces an existing archive."
        }
        if destinationIsOccupied {
            return "The folder \(destinationRoot.path) already exists and is not empty. mailin never removes files it did not write; move or rename that folder first."
        }
        if freeBytes < requiredBytes {
            return "Not enough space there: the archive needs about \(ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) is free."
        }
        return nil
    }

    /// F01 rule 1. Source and destination compared by canonical path — the
    /// same folder, the destination inside the source, or the source inside
    /// the destination all mean the copy would write into (or delete) what
    /// it is copying.
    var pathConflict: String? {
        let source = ArchiveRelocator.canonicalPath(sourceRoot)
        let destination = ArchiveRelocator.canonicalPath(destinationRoot)
        if source == destination {
            return "That is where the archive already is. Choose a different volume or folder."
        }
        if destination.hasPrefix(source + "/") {
            return "That folder is inside the archive itself. Choose a folder outside \(sourceRoot.path)."
        }
        if source.hasPrefix(destination + "/") {
            return "The archive is inside that folder. Choose a folder that does not contain \(sourceRoot.path)."
        }
        return nil
    }

    /// F01 rule 2. True when `destinationRoot` already holds someone's
    /// archive (an `emails.db`). A folder without one — a stale, unverified
    /// partial copy — is the only thing the relocator may replace.
    var destinationHoldsArchive: Bool { ArchiveLayout.hasArchive(at: destinationRoot) }

    /// Recheck R8: a pre-existing destination folder with ANY content is
    /// somebody's — the absence of `emails.db` is not evidence that it was a
    /// staging copy of ours (our staging folders are siblings with unique
    /// names, never the destination itself). Only an empty folder may be
    /// replaced.
    var destinationIsOccupied: Bool {
        ArchiveRelocator.isNonEmptyDirectory(destinationRoot)
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
        let embeddings = ArchiveLayout.embeddingsDirectory(under: sourceRoot)
        let (bytes, files) = measure([sqlite, fts, embeddings])
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
        // Re-evaluated here, not trusted from the plan: the plan may be
        // minutes old and the destination may have gained an archive since.
        // `pathConflict` and `destinationHoldsArchive` are computed fresh.
        if let why = plan.refusalReason { throw RelocationError.refused(why) }
        let fm = FileManager.default
        let sourceSQLite = ArchiveLayout.sqliteDirectory(under: plan.sourceRoot)
        let sourceFTS = ArchiveLayout.ftsDirectory(under: plan.sourceRoot)
        guard fm.fileExists(atPath: sourceSQLite.appendingPathComponent("emails.db").path) else {
            throw RelocationError.sourceMissing
        }
        // The store handed in must be the one over the source. A mismatch
        // means the caller's idea of "the archive" and the plan's disagree,
        // and the row-count verification below would be meaningless.
        guard canonicalPath(store.storeDirectory) == canonicalPath(sourceSQLite) else {
            throw RelocationError.refused("The open archive is not the one this move describes; relaunch mailin and try again.")
        }

        // Quiesce: WAL into the main file, idle shards closed, so the copy is
        // a set of self-contained files.
        try await store.checkpoint()
        _ = await fts.sweepIdleShards(ttl: .zero)
        let liveRows = try await store.totalCount()

        let clock = ContinuousClock()
        let start = clock.now

        // F01 rule 2: copy into a staging folder BESIDE the destination and
        // rename into place after it verifies. Nothing at the destination
        // path is touched until a verified replacement exists.
        let staging = plan.destinationRoot.deletingLastPathComponent()
            .appendingPathComponent("\(ArchiveLayout.relocatedFolderName).staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let stagingSQLite = ArchiveLayout.sqliteDirectory(under: staging)
        let stagingFTS = ArchiveLayout.ftsDirectory(under: staging)
        let stagingEmbeddings = ArchiveLayout.embeddingsDirectory(under: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var copied: Int64 = 0
        var files = 0
        let sourceEmbeddings = ArchiveLayout.embeddingsDirectory(under: plan.sourceRoot)
        do {
            // The plan measured the archive BEFORE the checkpoint (WAL included),
            // which is the right, conservative number for the free-space check.
            // Progress must be reported against what is actually copied, so
            // measure again now that the WAL has been folded into the main file.
            let (total, _) = measure([sourceSQLite, sourceFTS, sourceEmbeddings])
            for (from, to) in [(sourceSQLite, stagingSQLite), (sourceFTS, stagingFTS), (sourceEmbeddings, stagingEmbeddings)] {
                guard fm.fileExists(atPath: from.path) else { continue }
                try copyTree(from: from, to: to) { bytes in
                    copied += bytes
                    files += 1
                    progress?(copied, total)
                }
            }

            // Verify the staged copy: byte counts per file and the database hash.
            try verifyTree(source: sourceSQLite, destination: stagingSQLite)
            if fm.fileExists(atPath: sourceFTS.path) { try verifyTree(source: sourceFTS, destination: stagingFTS) }
            let sourceHash = try ArchiveExportService.sha256(ofFile: sourceSQLite.appendingPathComponent("emails.db"))
            let copyHash = try ArchiveExportService.sha256(ofFile: stagingSQLite.appendingPathComponent("emails.db"))
            guard sourceHash == copyHash else {
                throw RelocationError.verificationFailed("emails.db hash differs")
            }

            // Publish. Only an EMPTY pre-existing destination folder may be
            // replaced (R8): anything with content is not ours to remove,
            // whether or not it looks like an archive.
            if fm.fileExists(atPath: plan.destinationRoot.path) {
                guard !isNonEmptyDirectory(plan.destinationRoot) else {
                    throw RelocationError.refused("The folder \(plan.destinationRoot.path) gained content while copying. Nothing was replaced.")
                }
                try fm.removeItem(at: plan.destinationRoot)
            }
            try fm.moveItem(at: staging, to: plan.destinationRoot)
        } catch {
            // Only our own staging folder is ever cleaned up.
            try? fm.removeItem(at: staging)
            throw error
        }

        // A real open of the published copy must report the same row count.
        // The copy is ours (just moved into place), so a failed open removes it.
        let destinationSQLite = ArchiveLayout.sqliteDirectory(under: plan.destinationRoot)
        let copyStore = SQLiteEmailStore(directory: destinationSQLite)
        let copyRows = try await copyStore.totalCount()
        guard copyRows == liveRows else {
            try? fm.removeItem(at: plan.destinationRoot)
            throw RelocationError.verificationFailed("row count \(copyRows) ≠ \(liveRows)")
        }
        let sourceHash = try ArchiveExportService.sha256(ofFile: sourceSQLite.appendingPathComponent("emails.db"))

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
    /// one the RUNNING store has opened (`liveRoot`), so deleting it can never
    /// remove the only copy nor the files an open connection is still writing.
    /// Before the relaunch the running store is still on this Mac's copy and
    /// this returns nil (F01 rule 3).
    static func retiredCopyOnThisMac(defaultRoot: URL = ArchiveLayout.defaultRoot,
                                     record: RelocationRecord? = RelocationRecordStore.production.load(),
                                     liveRoot: URL = SQLiteEmailStore.shared.storeDirectory.deletingLastPathComponent()) -> URL? {
        guard let record, ArchiveLayout.hasArchive(at: record.destinationURL),
              ArchiveLayout.hasArchive(at: defaultRoot),
              canonicalPath(record.sourceURL) == canonicalPath(defaultRoot),
              canonicalPath(liveRoot) == canonicalPath(record.destinationURL),
              canonicalPath(liveRoot) != canonicalPath(defaultRoot) else { return nil }
        return defaultRoot
    }

    /// True when a verified move exists but the app has not been relaunched
    /// on it yet: the copy here is still live, so it cannot be deleted.
    static func moveAwaitsRelaunch(defaultRoot: URL = ArchiveLayout.defaultRoot,
                                   record: RelocationRecord? = RelocationRecordStore.production.load(),
                                   liveRoot: URL = SQLiteEmailStore.shared.storeDirectory.deletingLastPathComponent()) -> Bool {
        guard let record, ArchiveLayout.hasArchive(at: record.destinationURL),
              ArchiveLayout.hasArchive(at: defaultRoot) else { return false }
        return canonicalPath(liveRoot) == canonicalPath(defaultRoot)
    }

    static func deleteRetiredCopy(defaultRoot: URL = ArchiveLayout.defaultRoot,
                                  record: RelocationRecord? = RelocationRecordStore.production.load(),
                                  liveRoot: URL = SQLiteEmailStore.shared.storeDirectory.deletingLastPathComponent()) throws {
        guard let root = retiredCopyOnThisMac(defaultRoot: defaultRoot, record: record, liveRoot: liveRoot) else { return }
        for folder in [ArchiveLayout.sqliteFolder, ArchiveLayout.ftsFolder, ArchiveLayout.embeddingsFolder] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        relocationLog.notice("deleted the retired archive copy under \(root.path, privacy: .public)")
    }

    // MARK: Helpers

    /// True for an existing directory (or file) at `url` that has any entry
    /// at all, hidden files included. A missing path is not occupied.
    static func isNonEmptyDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return true }   // a file in the way is "occupied" too
        let entries = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        return !entries.isEmpty
    }

    /// One path for one place: standardized, symlinks resolved, no trailing
    /// slash. A path that does not exist yet is canonicalised through its
    /// nearest existing ancestor so `/Volumes/X/mailin-archive` and the same
    /// folder reached through an alias compare equal before it is created.
    static func canonicalPath(_ url: URL) -> String {
        let fm = FileManager.default
        var url = url.standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            tail.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var path = url.resolvingSymlinksInPath().path
        for component in tail { path = (path as NSString).appendingPathComponent(component) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

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
