//
//  ArchiveLocation.swift
//  mailin
//
//  B5: let the archive live on a volume the user chooses — an internal disk or
//  a local external SSD.
//
//  Why this is not simply "pick a folder". Three of the candidate folders a
//  user would naturally pick are actively unsafe for a live SQLite store, and
//  a storage feature that accepts them is worse than no feature:
//
//   • **iCloud Drive / any file-provider folder.** Apple's rule is explicit —
//     a SQLite database file must never be stored in iCloud. The store and its
//     `-wal` are separate files that sync independently, so the pair can be
//     reunited in an inconsistent combination. That is silent corruption, and
//     the archive is the evidence.
//   • **A network volume.** SQLite's locking depends on POSIX advisory locks
//     that most network filesystems implement incorrectly or not at all.
//   • **A FAT/exFAT volume.** exFAT caps a single file at 4 GB, so the archive
//     would fail partway through a large import with a confusing error.
//
//  So the picker validates, and refuses with the reason. A refusal the user
//  can act on beats an import that dies at 4 GB.
//
//  Shipped behind `Capability.externalStorage` (Preview, OFF by default).
//  Switching it off does not move anything: the archive stays exactly where it
//  is and only the ability to choose is hidden.
//

import Foundation
import os.log

private let locationLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin",
                                 category: "ArchiveLocation")

/// Where the archive is, or is being asked to be.
struct ArchiveLocation: Codable, Sendable, Equatable {
    /// The directory that contains `sqlite/`, `fts5/` and `blobs/`.
    var path: String
    /// Security-scoped bookmark, so access survives relaunch on macOS.
    var bookmark: Data?
    var recordedAt: Date

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

enum ArchiveLocationVerdict: Equatable, Sendable {
    case ok(freeBytes: Int64)
    /// Usable, but the user should know something first.
    case warn(String, freeBytes: Int64)
    /// Refused, with the reason and what to do instead.
    case refuse(String)

    var isUsable: Bool {
        switch self {
        case .ok, .warn: return true
        case .refuse: return false
        }
    }

    var message: String? {
        switch self {
        case .ok: return nil
        case .warn(let text, _): return text
        case .refuse(let text): return text
        }
    }
}

enum ArchiveLocationPolicy {

    /// exFAT's single-file ceiling. The database alone will pass it on any
    /// serious archive.
    static let exFATFileCeilingBytes: Int64 = 4 * 1_073_741_824

    /// Judges a candidate directory. Every refusal names the actual reason —
    /// a generic "unsupported location" would send the user guessing.
    static func verdict(for directory: URL) -> ArchiveLocationVerdict {
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .refuse("That folder does not exist.")
        }
        guard fm.isWritableFile(atPath: directory.path) else {
            return .refuse("mailin cannot write to that folder. Choose one you own, or adjust its permissions.")
        }

        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeSupportsFileCloningKey,
            .isUbiquitousItemKey,
            .volumeNameKey
        ])

        if values?.volumeIsReadOnly == true {
            return .refuse("That volume is read-only.")
        }

        // iCloud / file provider. Checked two ways because the resource value
        // only reports items already ubiquitous, while a path check catches
        // the container the user is about to write into.
        if values?.isUbiquitousItem == true || isCloudSynced(directory) {
            return .refuse("""
                That folder is synced by iCloud or another cloud service. A database there \
                can be corrupted, because its main file and its write-ahead log sync \
                independently and can be reunited in an inconsistent state. Choose a local \
                folder — an external SSD is fine.
                """)
        }

        if values?.volumeIsLocal == false {
            return .refuse("""
                That is a network volume. Database file locking is unreliable over the \
                network, which risks corrupting the archive. Choose a local disk.
                """)
        }

        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)

        // Filesystem format. `volumeSupportsFileCloning` is false on FAT and
        // exFAT and true on APFS/HFS+, which is the cheapest reliable signal
        // available without mount-table parsing.
        if values?.volumeSupportsFileCloning == false {
            return .warn("""
                That volume looks like FAT or exFAT, which cannot hold a single file larger \
                than 4 GB. The archive database will exceed that on a large import and the \
                import will fail partway. An APFS-formatted disk avoids it.
                """, freeBytes: free)
        }

        if free > 0, free < 2 * 1_073_741_824 {
            return .warn("""
                Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is \
                free there. Imports will be refused as soon as one does not fit.
                """, freeBytes: free)
        }

        if values?.volumeIsLocal == true, isRemovable(directory) {
            return .warn("""
                That is a removable volume. The archive is unreadable whenever it is \
                detached, and detaching it during an import will interrupt the import.
                """, freeBytes: free)
        }

        return .ok(freeBytes: free)
    }

    /// Path-based cloud detection, for a folder that is not yet ubiquitous.
    /// Deliberately conservative: these are the containers the sync clients
    /// actually use, and a false positive only costs the user a different
    /// folder choice.
    private static func isCloudSynced(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        let markers = [
            "/Library/Mobile Documents",     // iCloud Drive
            "/Library/CloudStorage",         // Dropbox, OneDrive, Google Drive via FileProvider
            "/Dropbox",
            "/OneDrive",
            "/Google Drive"
        ]
        return markers.contains { path.contains($0) }
    }

    private static func isRemovable(_ directory: URL) -> Bool {
        let values = try? directory.resourceValues(forKeys: [.volumeIsRemovableKey,
                                                             .volumeIsEjectableKey])
        return values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
    }
}

/// Records the chosen location. Does NOT move data — see `moveIsNotAutomated`.
struct ArchiveLocationStore: Sendable {
    let url: URL

    static var productionURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("archive-location.v1.json", isDirectory: false)
    }

    /// Recorded honesty, not a TODO: choosing a new location takes effect for
    /// a NEW archive only. Relocating an existing one means closing the live
    /// store, copying the directory, reopening at the destination and
    /// verifying the row count before anything is removed. That sequence is
    /// not implemented, so the UI says exactly where the archive is and lets
    /// the user move it themselves rather than half-doing it.
    ///
    /// `SQLiteEmailStore.productionDirectory` enforces the "new archive only"
    /// half: it adopts a chosen location ONLY when the default path holds no
    /// `emails.db`. An earlier version of this string promised new archives
    /// would use the chosen location while nothing read the stored value at
    /// all — the claim is now true as written.
    static let moveIsNotAutomated = """
        Choosing a new location does not move your existing archive, and mailin will keep using \
        the archive you already have. A location you pick here is used only when there is no \
        archive yet. To move what you already have, quit mailin, copy the archive folder to the \
        new location, and relaunch.
        """

    func load() -> ArchiveLocation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArchiveLocation.self, from: data)
    }

    func save(_ location: ArchiveLocation) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(location).write(to: url, options: .atomic)
            locationLog.info("archive location recorded: \(location.path, privacy: .public)")
        } catch {
            locationLog.error("could not record archive location: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        locationLog.info("archive location reset to the default")
    }

    /// Bookmark for a user-chosen directory so access survives relaunch under
    /// the sandbox. Returns nil when the bookmark cannot be made, which the
    /// caller treats as "usable this session only".
    static func bookmark(for directory: URL) -> Data? {
        #if os(macOS)
        return try? directory.bookmarkData(options: [.withSecurityScope],
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        #else
        return try? directory.bookmarkData(options: [],
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        #endif
    }
}
