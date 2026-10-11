//
//  ArchiveSafety.swift
//  ArchiveCore
//
//  3.0 database safety switches (SCALE_TODO_3_0.md §3-S1, S2, S9).
//
//  These are plain flags because the store opens connections from actor code
//  that cannot consult the app's main-actor capability registry. The app's
//  CapabilityWiring pushes the switch positions here (`v3SQLiteHygiene`,
//  `v3Snapshots`). Both default OFF, so a build with these engines behaves
//  exactly like the previous one until they are switched on.
//

import Foundation
import SQLite3

public enum SQLiteHygiene {
    /// Pushed by the app (`Capability.v3SQLiteHygiene`). Read when a connection
    /// opens, so a change applies to connections opened afterwards.
    nonisolated(unsafe) public static var isEnabled = false

    /// Applies the 3.0 connection settings to a freshly opened handle:
    ///  • busy timeout — wait up to 5 s for another connection instead of
    ///    failing at once with "database is locked";
    ///  • macOS: `checkpoint_fullfsync` — macOS `fsync` does not flush the drive
    ///    cache, so a power cut during a WAL checkpoint could otherwise leave
    ///    the database file referencing pages that never reached the disk.
    static func apply(to handle: OpaquePointer) {
        guard isEnabled else { return }
        sqlite3_exec(handle, "PRAGMA busy_timeout = 5000;", nil, nil, nil)
        #if os(macOS)
        sqlite3_exec(handle, "PRAGMA checkpoint_fullfsync = ON;", nil, nil, nil)
        #endif
        // §3-S9: checkpoints happen when the app is idle (`checkpointWhenIdle`);
        // the automatic one stays only as a safety net at ~40 MB of log, so a
        // large import is not interrupted by a checkpoint every 4 MB.
        sqlite3_exec(handle, "PRAGMA wal_autocheckpoint = 10000;", nil, nil, nil)
    }

    /// §3-S9: write transactions take the write lock up front
    /// (`BEGIN IMMEDIATE`), so a second connection gets a clean busy wait at
    /// the start instead of SQLITE_BUSY in the middle of a transaction. Off:
    /// the previous deferred `BEGIN`.
    public static var beginWrite: String { isEnabled ? "BEGIN IMMEDIATE TRANSACTION;" : "BEGIN TRANSACTION;" }
}

public enum ArchiveSnapshotPolicy {
    /// Pushed by the app (`Capability.v3Snapshots`).
    nonisolated(unsafe) public static var isEnabled = false

    /// How many scheduled ("rolling") snapshots to keep. Pre-migration
    /// snapshots are kept separately and are never rotated away by the
    /// schedule — they are the way back from an upgrade.
    public static let rollingKeep = 1

    /// Free space required beyond the snapshot itself, so a snapshot never
    /// fills the disk.
    public static let headroomBytes: Int64 = 512 * 1024 * 1024
}

/// One snapshot file on disk.
public struct ArchiveSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { url.lastPathComponent }
    public let url: URL
    public let date: Date
    public let reason: String
    public let bytes: Int64
}

public enum ArchiveSnapshotError: LocalizedError, Equatable {
    case notEnoughSpace(neededBytes: Int64, availableBytes: Int64)
    case snapshotFailed(String)
    case restoreFailed(String)
    case integrityCheckFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough free space for a snapshot: needs \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: available)) available. The archive was not changed."
        case .snapshotFailed(let why): return "The snapshot couldn't be written: \(why)"
        case .restoreFailed(let why): return "The snapshot couldn't be restored: \(why). The current archive was kept."
        case .integrityCheckFailed(let why): return "The snapshot failed its integrity check (\(why)); it was not restored."
        }
    }
}
