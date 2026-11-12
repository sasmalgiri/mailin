//
//  CaptureStatus.swift
//  MailConnectivity
//
//  Plan v4 V4-04 (§5.4): four independent kinds of completeness for one
//  connected account, and the one plain line the UI shows.
//
//    1. Acquisition  — `ConnectedCompleteness.acquisition` (archive tables):
//                      captured / remaining / failed / unavailable, and
//                      whether the remote inventory is known at all.
//    2. Preservation — `ConnectedCompleteness.preservation`: records with
//                      bytes, byte total (SHA-256 per record), unreadable.
//    3. Search       — reported by the existing coverage code (search_docs /
//                      attachment coverage) through `SearchCoverageProbe`.
//    4. Export       — reported by the existing export receipts /
//                      reconciliation through `ExportVerificationProbe`.
//
//  A locally rehashed file never proves the remote enumeration was complete,
//  so acquisition is never derived from preservation (or vice versa).
//
//  `Headline` is a value, not a string: the app maps each case onto its
//  localised wording (rule 10). `defaultText` is the English reference.
//

import ArchiveCore
import Foundation

/// Search coverage of an account's preserved mail, from the existing coverage APIs.
public struct SearchCoverageSnapshot: Sendable, Equatable {
    public var bodiesIndexed: Int
    public var bodiesPending: Int
    public var attachmentsIndexed: Int
    public var attachmentsPending: Int
    /// Locked, unsupported or failed attachment text.
    public var attachmentsUnavailable: Int
    public init(bodiesIndexed: Int, bodiesPending: Int, attachmentsIndexed: Int, attachmentsPending: Int, attachmentsUnavailable: Int) {
        self.bodiesIndexed = bodiesIndexed; self.bodiesPending = bodiesPending; self.attachmentsIndexed = attachmentsIndexed
        self.attachmentsPending = attachmentsPending; self.attachmentsUnavailable = attachmentsUnavailable
    }
}

/// Export verification, from the existing export receipts.
public struct ExportVerificationSnapshot: Sendable, Equatable {
    public var exportsVerified: Int
    public var exportsWithMismatches: Int
    public var lastVerifiedAt: Date?
    public init(exportsVerified: Int, exportsWithMismatches: Int, lastVerifiedAt: Date?) {
        self.exportsVerified = exportsVerified; self.exportsWithMismatches = exportsWithMismatches; self.lastVerifiedAt = lastVerifiedAt
    }
}

public typealias SearchCoverageProbe = @Sendable (UUID) async -> SearchCoverageSnapshot?
public typealias ExportVerificationProbe = @Sendable (UUID) async -> ExportVerificationSnapshot?

public struct CaptureStatus: Sendable, Equatable {
    public enum Headline: Sendable, Equatable {
        /// "Account needs sign-in; saved mail remains available"
        case needsSignIn
        /// "Capture paused: drive unavailable" / "…: not enough free space" / provider limits
        case paused(SyncPauseReason)
        /// "Capture is not allowed for this account" (network policy refused)
        case notPermitted
        /// "Saving mail: N saved, M to go" (M unknown until the inventory is known)
        case capturing(saved: Int, remaining: Int?)
        /// "N saved; the mailbox has not been fully listed yet"
        case inventoryUnknown(saved: Int)
        /// "Saved locally; N could not be downloaded yet" (failed, retried next sync)
        case savedWithFailures(saved: Int, failed: Int)
        /// "Saved locally; attachment text pending"
        case savedTextPending(saved: Int)
        /// "Up to date: N saved (selected folders), checked <date>"
        case upToDate(saved: Int, reconciledAt: Date?)
        /// "Last capture stopped: <reason>; saved mail remains available"
        case lastRunStopped(String)
    }

    public var accountID: UUID
    public var state: AccountSyncState
    public var completeness: ConnectedCompleteness
    public var search: SearchCoverageSnapshot?
    public var export: ExportVerificationSnapshot?
    /// V4-12: the archive drive to reconnect, when capture paused because it is gone.
    public var missingDrive: ArchiveDriveIdentity? = nil

    public var lastSuccessfulSync: Date? { completeness.runs.lastSuccessfulAt }
    public var lastAttemptedSync: Date? { completeness.runs.lastAttemptedAt }

    /// True only when the selected scope is enumerated, reconciled, and
    /// nothing is pending or failed — the only state that may say "up to date".
    public var acquisitionComplete: Bool {
        let a = completeness.acquisition
        return a.inventoryKnown && a.remaining == 0 && a.failed == 0
    }

    public var headline: Headline {
        let a = completeness.acquisition
        let saved = a.captured - a.locallyDeleted
        switch state {
        case .needsSignIn: return .needsSignIn
        case .paused(let why): return .paused(why)
        case .notPermitted: return .notPermitted
        case .syncing, .backingOff: return .capturing(saved: saved, remaining: a.inventoryKnown ? a.remaining : nil)
        case .failed(let why): return .lastRunStopped(why)
        case .cancelled, .idle: break
        }
        if !a.inventoryKnown || a.remaining > 0 { return .inventoryUnknown(saved: saved) }
        if a.failed > 0 { return .savedWithFailures(saved: saved, failed: a.failed) }
        let textPending = completeness.preservation.unreadable > 0
            || (search.map { $0.bodiesPending > 0 || $0.attachmentsPending > 0 } ?? false)
        if textPending { return .savedTextPending(saved: saved) }
        return .upToDate(saved: saved, reconciledAt: a.reconciledAt)
    }

    /// English reference wording (the app localises from `headline`).
    public var defaultText: String {
        switch headline {
        case .needsSignIn: return "Account needs sign-in; saved mail remains available"
        case .paused(.driveUnavailable):
            if let drive = missingDrive { return "Capture paused: reconnect the drive “\(drive.volumeName)” that holds the archive" }
            return "Capture paused: drive unavailable"
        case .paused(.diskFull): return "Capture paused: not enough free space"
        case .paused(.quotaExceeded): return "Capture paused: the provider's limit was reached; it resumes later"
        case .paused(.rateLimited): return "Capture paused: the provider asked mailin to slow down; it resumes later"
        case .notPermitted: return "Capture is not allowed for this account"
        case .capturing(let saved, let remaining?): return "Saving mail: \(saved) saved, \(remaining) to go"
        case .capturing(let saved, nil): return "Saving mail: \(saved) saved so far"
        case .inventoryUnknown(let saved): return "\(saved) saved; the mailbox has not been fully listed yet"
        case .savedWithFailures(_, let failed): return "Saved locally; \(failed) could not be downloaded yet"
        case .savedTextPending: return "Saved locally; attachment text pending"
        case .upToDate(let saved, _): return "Up to date: \(saved) saved from the selected folders"
        case .lastRunStopped(let why): return "Last capture stopped (\(why)); saved mail remains available"
        }
    }
}
