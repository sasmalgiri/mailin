//
//  RecoveryDetectors.swift
//  ArchiveCore
//
//  3.1 R3/R4/R8: recognising deleted mail from what the mail client left in the
//  message itself. Pure functions over headers / flags, so every parser (the
//  streaming mbox parser, the offset engine, EML, EMLX) applies the same rules.
//
//  Thunderbird keeps message state in `X-Mozilla-Status` (hex bit flags). Bit
//  0x0008 means "expunged": the message was deleted (moved or removed) but stays
//  in the mbox until the folder is compacted. Pine/mutt-style clients mark a
//  deleted message with `D` in `X-Status`. Gmail Takeout lists the message's
//  labels in `X-Gmail-Labels`; "Trash"/"Bin" means it was in the trash.
//

import Foundation

/// Switches pushed by the app (`Capability.v3Recovery`, `.v3DeepRecovery`).
public enum RecoveryPolicy {
    /// Header/flag/folder detection (cheap; runs during every import when on).
    nonisolated(unsafe) public static var isEnabled = false
    /// PST allocation-map scanning and MIME carving (slow; per source).
    nonisolated(unsafe) public static var deepRecoveryEnabled = false
}

public enum RecoveryDetector {
    /// Thunderbird "expunged" bit.
    public static let mozillaExpunged: UInt32 = 0x0008

    /// Recovery state from a parsed message's headers and labels; nil = live.
    public static func fromHeaders(_ headers: [String: String], labels: [String]) -> RecoveryInfo? {
        guard RecoveryPolicy.isEnabled else { return nil }
        if let raw = value(headers, "X-Mozilla-Status"),
           let flags = UInt32(raw.trimmingCharacters(in: .whitespaces), radix: 16),
           flags & mozillaExpunged != 0 {
            return RecoveryInfo(state: .unpurged, method: "x-mozilla-status",
                                evidence: "X-Mozilla-Status \(raw.trimmingCharacters(in: .whitespaces))")
        }
        if let xs = value(headers, "X-Status"), xs.uppercased().contains("D") {
            return RecoveryInfo(state: .flaggedDeleted, method: "x-status", evidence: "X-Status \(xs)")
        }
        if let trash = labels.first(where: { DeletedFolderNames.isDeleted(path: $0) }) {
            return RecoveryInfo(state: .deletedFolder, method: "gmail-label",
                                evidence: "label \(trash)", folder: trash)
        }
        return nil
    }

    /// Apple Mail EMLX flags (bit 1 = deleted) and the mailbox it sat in.
    public static func fromEMLX(flags: Int?, mailboxPath: String?) -> RecoveryInfo? {
        guard RecoveryPolicy.isEnabled else { return nil }
        if let flags, flags & 0x02 != 0 {
            return RecoveryInfo(state: .flaggedDeleted, method: "emlx-flags",
                                evidence: String(format: "EMLX flags 0x%llx", flags), folder: mailboxPath)
        }
        if let mailboxPath, DeletedFolderNames.isDeleted(path: mailboxPath) {
            return RecoveryInfo(state: .deletedFolder, method: "emlx-mailbox",
                                evidence: "mailbox \(mailboxPath)", folder: mailboxPath)
        }
        return nil
    }

    /// A message found in a folder of a PST/OST (or any foldered source).
    public static func fromFolder(_ path: String, method: String) -> RecoveryInfo? {
        guard RecoveryPolicy.isEnabled, DeletedFolderNames.isDeleted(path: path) else { return nil }
        return RecoveryInfo(state: .deletedFolder, method: method, evidence: "folder \(path)", folder: path)
    }

    /// Case-insensitive header lookup.
    static func value(_ headers: [String: String], _ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

extension MBOXParser.RawEmail {
    /// The same email carrying a recovery record (chainable in builders).
    func withRecovery(_ info: RecoveryInfo?) -> MBOXParser.RawEmail {
        var copy = self
        copy.recovery = info
        return copy
    }
}
