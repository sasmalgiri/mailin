//
//  ArchiveDrive.swift
//  MailConnectivity
//
//  Plan v4 V4-12 (§7 External storage, T22/T23): an archive on an external
//  drive. When the drive disappears during capture, every engine pauses and
//  names THAT drive; nothing ever starts a second archive somewhere else —
//  not in an empty mount-point folder left behind on the boot disk, not in a
//  fallback copy — and capture resumes from its checkpoints when the drive
//  returns.
//
//  `ArchiveDriveIdentity` is recorded when the archive is placed (the app
//  already keeps the location + security-scoped bookmark in
//  `ArchiveLocation`); `ArchiveDriveGuard.check` compares the live volume
//  with it before anything touches the store:
//
//    present        the store folder is on the recorded volume (UUID) and
//                   holds the archive database
//    missing        the store folder is not there (drive unplugged)
//    otherVolume    the path exists but on ANOTHER volume (e.g. the empty
//                   mount-point folder on the boot disk) — refused, because
//                   writing there would silently create a second archive
//    archiveMissing the volume is back but holds no archive database at the
//                   recorded place — refused for the same reason
//
//  `StorageProbe.guarded(by:)` makes the sync engine see only "present"
//  volumes; any other answer is "drive unavailable", reported with the
//  drive's name. `ArchiveDriveMonitor` turns successive checks into
//  disappeared / returned events; on return the caller reopens the store
//  connection (`ConnectedArchiveSink.reopenAfterDriveReturned`) and runs the
//  engines again, which resume from their committed checkpoints.
//

import ArchiveCore
import Foundation

/// The drive (volume) an archive lives on, as recorded when it was placed.
public struct ArchiveDriveIdentity: Sendable, Equatable, Codable {
    /// The volume's UUID (APFS / HFS+ / exFAT where the file system has one).
    public var volumeUUID: String?
    /// The name the user sees in Finder ("Archive SSD").
    public var volumeName: String
    /// Where the volume was mounted when recorded ("/Volumes/Archive SSD").
    public var mountPath: String
    /// The archive store folder (holds `emails.db`).
    public var storePath: String
    public var isRemovable: Bool

    public init(volumeUUID: String?, volumeName: String, mountPath: String, storePath: String, isRemovable: Bool) {
        self.volumeUUID = volumeUUID; self.volumeName = volumeName; self.mountPath = mountPath
        self.storePath = storePath; self.isRemovable = isRemovable
    }

    /// Reads the identity of the volume holding `storeDirectory` (which must exist).
    public static func of(storeDirectory: URL) throws -> ArchiveDriveIdentity {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let values = try storeDirectory.resourceValues(forKeys: keys)
        return ArchiveDriveIdentity(volumeUUID: values.volumeUUIDString, volumeName: values.volumeName ?? storeDirectory.lastPathComponent,
                                    mountPath: values.volume?.path ?? "/", storePath: storeDirectory.standardizedFileURL.path,
                                    isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false))
    }
}

public enum ArchiveDriveCheck: Sendable, Equatable {
    case present(availableBytes: Int64?)
    case missing
    /// The store path exists, but on a different volume (named) than the recorded one.
    case otherVolume(found: String)
    /// The recorded volume is there but the archive database is not.
    case archiveMissing

    public var isPresent: Bool { if case .present = self { return true }; return false }
}

public enum ArchiveDriveError: LocalizedError, Equatable {
    case unavailable(ArchiveDriveIdentity, ArchiveDriveCheck)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let drive, .otherVolume(let found)):
            return "The archive's drive “\(drive.volumeName)” is not connected; \(drive.storePath) is now on “\(found)”. Nothing was written there. Reconnect “\(drive.volumeName)”."
        case .unavailable(let drive, .archiveMissing):
            return "The drive “\(drive.volumeName)” is connected but the archive is not at \(drive.storePath). Nothing was written; no new archive was started."
        case .unavailable(let drive, _):
            return "The archive's drive “\(drive.volumeName)” is not connected. Capture is paused and resumes when it is reconnected."
        }
    }
}

public enum ArchiveDriveGuard {
    public static let databaseName = "emails.db"

    /// Compares the live volume with the recorded identity. Never creates anything.
    public static func check(_ drive: ArchiveDriveIdentity,
                             availableBytes: @Sendable (URL) -> Int64? = StorageProbe.volumeAvailableBytes) -> ArchiveDriveCheck {
        let fm = FileManager.default
        let store = URL(fileURLWithPath: drive.storePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: store.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        let values = try? store.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        if let expected = drive.volumeUUID {
            guard let found = values?.volumeUUIDString else { return .missing }
            if found.caseInsensitiveCompare(expected) != .orderedSame {
                return .otherVolume(found: values?.volumeName ?? "another disk")
            }
        }
        guard fm.fileExists(atPath: store.appendingPathComponent(databaseName).path) else { return .archiveMissing }
        return .present(availableBytes: availableBytes(store))
    }

    /// Throws unless the archive is on its drive — call before opening or
    /// reopening the store, so a missing drive never yields an empty archive.
    public static func requirePresent(_ drive: ArchiveDriveIdentity) throws {
        let result = check(drive)
        guard result.isPresent else { throw ArchiveDriveError.unavailable(drive, result) }
    }
}

extension StorageProbe {
    /// A probe that reports free space only while the archive is on its
    /// recorded drive; otherwise "unreachable" (the engine pauses with
    /// `.driveUnavailable` and names `drive`).
    public static func guarded(by drive: ArchiveDriveIdentity, reserveBytes: Int64 = 256 * 1_048_576,
                               availableBytes: @escaping @Sendable (URL) -> Int64? = StorageProbe.volumeAvailableBytes) -> StorageProbe {
        StorageProbe(reserveBytes: reserveBytes, availableBytes: { _ in
            guard case .present(let free) = ArchiveDriveGuard.check(drive, availableBytes: availableBytes) else { return nil }
            return free
        }, drive: drive)
    }
}

/// Turns successive drive checks into events (poll it from a timer, a
/// volume-mount notification or before each scheduled capture).
public actor ArchiveDriveMonitor {
    public enum Event: Sendable, Equatable {
        case disappeared(ArchiveDriveCheck)
        case returned
    }

    public nonisolated let drive: ArchiveDriveIdentity
    private let availableBytes: @Sendable (URL) -> Int64?
    public private(set) var last: ArchiveDriveCheck

    public init(drive: ArchiveDriveIdentity, availableBytes: @escaping @Sendable (URL) -> Int64? = StorageProbe.volumeAvailableBytes) {
        self.drive = drive
        self.availableBytes = availableBytes
        self.last = ArchiveDriveGuard.check(drive, availableBytes: availableBytes)
    }

    /// The change since the previous poll, if any.
    public func poll() -> Event? {
        let now = ArchiveDriveGuard.check(drive, availableBytes: availableBytes)
        defer { last = now }
        switch (last.isPresent, now.isPresent) {
        case (true, false): return .disappeared(now)
        case (false, true): return .returned
        case (false, false) where now != last: return .disappeared(now)
        default: return nil
        }
    }

    /// On `.returned`: the store's old connection points at the vanished
    /// mount, so it is reopened (after the guard confirms the archive is
    /// back) and interrupted captures are reconciled. Call only while the
    /// account engines are not running (they are paused while the drive is gone).
    public func reopen(_ sink: ConnectedArchiveSink) async throws -> ConnectedReconcileReport {
        try ArchiveDriveGuard.requirePresent(drive)
        await sink.reopenAfterDriveReturned()
        return try await sink.reconcileAfterRestart()
    }
}
