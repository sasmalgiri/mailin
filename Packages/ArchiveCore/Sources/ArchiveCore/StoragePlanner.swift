//
//  StoragePlanner.swift
//  mailin
//
//  S2 of SIZE_LIMITS_DESIGN.md — decide before an import starts whether it can
//  finish, and if not, say exactly how many bytes are missing.
//
//  This is what lets the size *refusals* go away. S1 replaced "file too large"
//  with "not tested above N", which is only honest if something else still
//  stops an import that genuinely cannot fit. That something is this.
//
//  Coefficients are MEASURED, not guessed. Importing the 94,915,160-byte
//  owner fixture (526 messages, 152 with attachments) produced:
//
//      store  117,969,840 bytes  → 1.243 × source
//      FTS      4,132,864 bytes  → 0.044 × source
//      total                     → 1.286 × source
//
//  The store exceeds the source because it keeps the raw MIME *and* the
//  extracted plain/HTML text *and* headers JSON *and* its indexes. The FTS
//  ratio is low here because that corpus is attachment-heavy and the index
//  budget (S0) bounds indexed text per message; a text-heavy corpus will index
//  far more, so the planner deliberately assumes a higher index ratio than was
//  measured. Both are to be re-derived per corpus shape in P9.
//

import Foundation

struct StorageRequirement: Sendable, Equatable {
    /// Bytes of source being imported.
    var sourceBytes: Int64
    /// A copy of the originals, when the user chose to copy rather than
    /// reference them.
    var originalCopyBytes: Int64
    /// SQLite store growth (raw MIME + extracted text + headers + indexes).
    var storeBytes: Int64
    /// FTS shard growth.
    var indexBytes: Int64
    /// Write-ahead log headroom before a checkpoint reclaims it.
    var walBytes: Int64
    /// Temp spool for one oversized item at a time.
    var spoolBytes: Int64
    /// A small floor so a completed import never leaves the volume at zero.
    /// Deliberately NOT a volume-proportional margin: refusing a 95 MB import
    /// because a 500 GB disk is low on space is not mailin's call. The larger
    /// comfort margin drives the `tight` warning instead.
    var hardFloorBytes: Int64

    /// What the import genuinely cannot finish without.
    var total: Int64 {
        originalCopyBytes + storeBytes + indexBytes + walBytes + spoolBytes + hardFloorBytes
    }

    /// Human breakdown, so a refusal can be argued with.
    var breakdown: [(label: String, bytes: Int64)] {
        var rows: [(String, Int64)] = []
        if originalCopyBytes > 0 { rows.append(("Copy of the original files", originalCopyBytes)) }
        rows.append(("Archive database", storeBytes))
        rows.append(("Search index", indexBytes))
        rows.append(("Database write-ahead log", walBytes))
        rows.append(("Temporary working space", spoolBytes))
        rows.append(("Reserved so the disk is never filled", hardFloorBytes))
        return rows
    }
}

enum StoragePlan: Sendable, Equatable {
    /// Comfortably fits.
    case ok(StorageRequirement, freeBytes: Int64)
    /// Fits, but with little room afterwards — proceed and say so.
    case tight(StorageRequirement, freeBytes: Int64, remainingAfter: Int64)
    /// Cannot finish. `missingBytes` is the shortfall, not a vague failure.
    case insufficient(StorageRequirement, freeBytes: Int64, missingBytes: Int64)

    var requirement: StorageRequirement {
        switch self {
        case .ok(let r, _), .tight(let r, _, _), .insufficient(let r, _, _): return r
        }
    }

    var canProceed: Bool {
        if case .insufficient = self { return false }
        return true
    }

    /// One sentence for the import sheet or the refusal.
    var summary: String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch self {
        case .ok(let requirement, let free):
            return "Needs about \(fmt(requirement.total)); \(fmt(free)) free."
        case .tight(let requirement, let free, let remaining):
            return "Needs about \(fmt(requirement.total)) of the \(fmt(free)) free, leaving only \(fmt(remaining)). The import will run, but free up space soon."
        case .insufficient(let requirement, let free, let missing):
            return "Not enough space: this import needs about \(fmt(requirement.total)) but only \(fmt(free)) is free — \(fmt(missing)) short. Free up space, choose another destination, or import fewer files."
        }
    }
}

enum StoragePlanner {

    // MARK: Measured coefficients

    /// Store growth per byte of source. Measured 1.243 on the owner fixture;
    /// rounded up for headroom.
    static let storeRatio = 1.30
    /// Index growth per byte of source. Measured 0.044 on an attachment-heavy
    /// corpus, where the S0 text budget bounds what gets indexed. Text-heavy
    /// mail indexes much more, so this assumption is deliberately ~4× the
    /// measurement rather than the measurement itself.
    static let indexRatio = 0.20
    /// WAL headroom ceiling. The allowance scales with the work (half the
    /// source) and is capped here, because the importer checkpoints as it goes.
    /// A flat allowance made a 95 MB import claim it needed gigabytes.
    static let maxWALAllowanceBytes: Int64 = 512 * 1_048_576       // 512 MiB
    /// Temp spool ceiling for one oversized item at a time; also scaled to the
    /// source, since a 95 MB import cannot contain a 1 GiB message.
    static let maxSpoolAllowanceBytes: Int64 = 1_073_741_824       // 1 GiB
    /// Never fill the volume completely, whatever the import needs.
    static let hardFloorBytes: Int64 = 1_073_741_824               // 1 GiB
    /// Comfort headroom used only to decide `tight`: 2 % of the volume,
    /// clamped so a 4 TB disk is not asked for 80 GB.
    static let minimumComfortMarginBytes: Int64 = 2 * 1_073_741_824   // 2 GiB
    static let maximumComfortMarginBytes: Int64 = 20 * 1_073_741_824  // 20 GiB

    static func comfortMargin(volumeCapacityBytes: Int64) -> Int64 {
        let twoPercent = Int64(Double(volumeCapacityBytes) * 0.02)
        return min(max(twoPercent, minimumComfortMarginBytes), maximumComfortMarginBytes)
    }

    // MARK: Planning

    static func requirement(sourceBytes: Int64,
                            copyOriginals: Bool,
                            volumeCapacityBytes: Int64) -> StorageRequirement {
        return StorageRequirement(
            sourceBytes: sourceBytes,
            originalCopyBytes: copyOriginals ? sourceBytes : 0,
            storeBytes: Int64(Double(sourceBytes) * storeRatio),
            indexBytes: Int64(Double(sourceBytes) * indexRatio),
            walBytes: min(sourceBytes / 2, maxWALAllowanceBytes),
            spoolBytes: min(sourceBytes, maxSpoolAllowanceBytes),
            hardFloorBytes: hardFloorBytes
        )
    }

    static func plan(sourceBytes: Int64,
                     copyOriginals: Bool,
                     freeBytes: Int64,
                     volumeCapacityBytes: Int64) -> StoragePlan {
        let requirement = requirement(sourceBytes: sourceBytes,
                                      copyOriginals: copyOriginals,
                                      volumeCapacityBytes: volumeCapacityBytes)
        let remaining = freeBytes - requirement.total
        if remaining < 0 {
            return .insufficient(requirement, freeBytes: freeBytes, missingBytes: -remaining)
        }
        if remaining < comfortMargin(volumeCapacityBytes: volumeCapacityBytes) {
            return .tight(requirement, freeBytes: freeBytes, remainingAfter: remaining)
        }
        return .ok(requirement, freeBytes: freeBytes)
    }

    /// Plans against a real destination volume.
    ///
    /// Unknown free space is treated as **insufficient**, not as unlimited: an
    /// unreadable volume must not silently unlock a multi-hundred-gigabyte
    /// import.
    static func plan(sources: [URL],
                     destination: URL,
                     copyOriginals: Bool = true) -> StoragePlan {
        let sourceBytes = sources.reduce(Int64(0)) { total, url in
            total + ((try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        // The destination often does not exist yet — the first import creates
        // it. Query the nearest existing ancestor instead: a missing
        // subdirectory is not an unreadable volume, and conflating the two
        // refused every import.
        let probe = nearestExistingDirectory(of: destination)
        let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        return plan(sourceBytes: sourceBytes,
                    copyOriginals: copyOriginals,
                    freeBytes: free,
                    volumeCapacityBytes: capacity)
    }

    /// Walks up until it finds a directory that exists, so volume capacity can
    /// be read for a destination that has not been created yet.
    static func nearestExistingDirectory(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        let fm = FileManager.default
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent == candidate { break }
            candidate = parent
        }
        return URL(fileURLWithPath: "/")
    }

    // MARK: On-disk footprint

    /// What an archive currently occupies, split by tier.
    ///
    /// The blob tier has to be counted separately because after S3b it is not
    /// a rounding error: a corpus of large messages keeps most of its bytes in
    /// `blobs/`, and a "database size" that ignored them would understate the
    /// archive by orders of magnitude — exactly the kind of number that later
    /// gets quoted in a claim.
    struct ArchiveFootprint: Sendable, Equatable {
        /// `emails.db` itself.
        var databaseBytes: Int64
        /// `-wal` + `-shm`. Transient, but real while they exist.
        var journalBytes: Int64
        /// `blobs/` — raw MIME stored outside the row.
        var blobBytes: Int64
        /// FTS shard databases, if they live under the same directory.
        var indexBytes: Int64

        var total: Int64 { databaseBytes + journalBytes + blobBytes + indexBytes }

        var summary: String {
            func mb(_ bytes: Int64) -> String {
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
            return "\(mb(total)) total — database \(mb(databaseBytes)), "
                + "bodies \(mb(blobBytes)), index \(mb(indexBytes)), journal \(mb(journalBytes))"
        }
    }

    static func archiveFootprint(storeDirectory: URL) -> ArchiveFootprint {
        let fm = FileManager.default
        func size(of url: URL) -> Int64 {
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        func directoryBytes(_ url: URL) -> Int64 {
            guard let walker = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey],
                                             options: []) else { return 0 }
            var total: Int64 = 0
            for case let child as URL in walker {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }

        let db = storeDirectory.appendingPathComponent("emails.db")
        // The FTS5 shards are a SIBLING of the store directory
        // (`…/com.ecosanskriti.mailin/fts5`, beside `…/sqlite`), not a child —
        // see `FTSSearchIndex`. An isolated test store has no sibling, and the
        // existence check below reports 0 rather than inventing a number.
        let indexDirectory = storeDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("fts5", isDirectory: true)
        return ArchiveFootprint(
            databaseBytes: size(of: db),
            journalBytes: size(of: URL(fileURLWithPath: db.path + "-wal"))
                + size(of: URL(fileURLWithPath: db.path + "-shm")),
            blobBytes: directoryBytes(storeDirectory.appendingPathComponent("blobs", isDirectory: true)),
            indexBytes: fm.fileExists(atPath: indexDirectory.path) ? directoryBytes(indexDirectory) : 0
        )
    }
}
