//
//  RemoteOperation.swift
//  MailConnectivity
//
//  Plan v4 V4-11 (§3 A17, §6 "Server actions and safe cleanup", T41–T43,
//  RQ10): one journalled change to ONE message on the provider. A
//  `RemoteOperation` is written to disk BEFORE anything is sent and carries:
//
//   • the account (UUID) and the stable provider identity (Gmail message id,
//     Graph mailbox + immutable id, IMAP mailbox + UIDVALIDITY + UID);
//   • the requested change (`RemoteChangeRequest`);
//   • the expected prior state (`RemotePrecondition`) — what must still be
//     true on the server for the change to be the one the user reviewed;
//   • the attempt state (`planned → executing → finished`), persisted before
//     the mutating request, so a process killed mid-request is reconciled,
//     never blindly repeated;
//   • the outcome — applied / conflict / uncertain / rejected — decided for
//     THIS item only (never "the batch was sent, so all succeeded").
//
//  Server "Archive" (Gmail: remove the Inbox label) is a provider change and
//  is unrelated to "Preserve in mailin" (the archive's own copy). No server
//  action ever touches the archive's copy of a message.
//

import ArchiveCore
import Foundation

/// One requested change to one message on its provider.
public enum RemoteChangeRequest: Codable, Sendable, Equatable, Hashable {
    case markRead
    case markUnread
    case flag
    case unflag
    /// Gmail only: add a label (label id).
    case addLabel(String)
    /// Gmail only: remove a label (label id).
    case removeLabel(String)
    /// Gmail's server "Archive": remove the INBOX label. The message stays in
    /// All Mail and in every other label. Not the same as preserving it in mailin.
    case archiveOnServer
    /// Folder move (Graph folder id or well-known name, IMAP mailbox name;
    /// Gmail: remove label `from`, add label `to`).
    case move(from: String, to: String)
    /// Move to the provider's Trash / Deleted Items from `from`.
    case moveToTrash(from: String)
    /// Back out of Trash. `to`: the folder to restore into (Graph, IMAP);
    /// Gmail's untrash restores the message's own labels and ignores it.
    case restoreFromTrash(to: String?)

    /// The words the receipt and the preview use (the app localises from the case).
    public var defaultText: String {
        switch self {
        case .markRead: return "Mark as read"
        case .markUnread: return "Mark as unread"
        case .flag: return "Flag"
        case .unflag: return "Remove flag"
        case .addLabel(let l): return "Add label \(l)"
        case .removeLabel(let l): return "Remove label \(l)"
        case .archiveOnServer: return "Archive on the server (remove from Inbox)"
        case .move(let from, let to): return "Move from \(from) to \(to)"
        case .moveToTrash(let from): return "Move from \(from) to Trash"
        case .restoreFromTrash(let to): return "Restore from Trash" + (to.map { " to \($0)" } ?? "")
        }
    }

    /// True for the changes that take a message out of where the user sees it.
    public var removesFromFolder: Bool {
        switch self {
        case .move, .moveToTrash, .archiveOnServer, .removeLabel: return true
        default: return false
        }
    }
}

/// What the server says about one message right now.
public struct RemoteItemState: Codable, Sendable, Equatable {
    /// false = the provider no longer has this identity (expunged, deleted,
    /// moved under a non-immutable id, UIDVALIDITY changed).
    public var exists: Bool
    public var isRead: Bool?
    public var isFlagged: Bool?
    /// Gmail: label ids. Graph: [parentFolderId]. IMAP: [mailbox].
    public var folders: [String]
    public var inTrash: Bool
    /// historyId / changeKey / MODSEQ when the provider reports one.
    public var revision: String?

    public init(exists: Bool, isRead: Bool? = nil, isFlagged: Bool? = nil, folders: [String] = [], inTrash: Bool = false,
                revision: String? = nil) {
        self.exists = exists; self.isRead = isRead; self.isFlagged = isFlagged; self.folders = folders
        self.inTrash = inTrash; self.revision = revision
    }

    public static let gone = RemoteItemState(exists: false)
}

/// The expected prior state, frozen with the operation. A server state that
/// matches neither this nor the requested result is a CONFLICT: another
/// client changed the message, and nothing is sent for it.
public struct RemotePrecondition: Codable, Sendable, Equatable {
    /// The message must (still) be in this folder / carry this label.
    public var inFolder: String?
    /// The message must not be in Trash (every change except restore).
    public var notInTrash: Bool
    /// Restore: the message must be in Trash.
    public var inTrash: Bool

    public init(inFolder: String? = nil, notInTrash: Bool = true, inTrash: Bool = false) {
        self.inFolder = inFolder; self.notInTrash = notInTrash; self.inTrash = inTrash
    }

    /// The precondition a request implies.
    public static func implied(by request: RemoteChangeRequest) -> RemotePrecondition {
        switch request {
        case .move(let from, _), .moveToTrash(let from): return RemotePrecondition(inFolder: from)
        case .archiveOnServer: return RemotePrecondition()
        case .restoreFromTrash: return RemotePrecondition(notInTrash: false, inTrash: true)
        default: return RemotePrecondition()
        }
    }
}

/// Why an operation was refused. Nothing was changed on the server.
public enum RemoteRejection: Codable, Sendable, Equatable {
    /// The account's "Change server mail" permission is off.
    case changeServerMailOff
    /// The account's sign-in does not include the change scope (gmail.modify, Mail.ReadWrite).
    case needsExtraPermission(scope: String)
    /// The network policy refused the request.
    case networkNotPermitted(String)
    case needsSignIn
    /// The provider cannot do this (e.g. labels on IMAP).
    case unsupported(String)
    /// IMAP without MOVE or UIDPLUS: a targeted removal is impossible without
    /// a mailbox-wide EXPUNGE, which mailin never sends (T42).
    case targetedRemovalUnavailable(String)
    /// The provider answered with a definite refusal (4xx / NO).
    case providerRefused(String)
    /// The current state could not be read, so nothing was attempted.
    case stateUnavailable(String)
    case accountMismatch

    public var defaultText: String {
        switch self {
        case .changeServerMailOff: return "Changing mail on the server is switched off for this account."
        case .needsExtraPermission(let scope): return "This needs extra permission: sign in again and allow mailin to change mail (\(scope))."
        case .networkNotPermitted(let why): return "The server was not contacted: \(why)"
        case .needsSignIn: return "This account needs you to sign in again."
        case .unsupported(let why): return why
        case .targetedRemovalUnavailable(let why): return why
        case .providerRefused(let why): return "The server refused the change: \(why)"
        case .stateUnavailable(let why): return "The message's current state could not be read (\(why)); nothing was changed."
        case .accountMismatch: return "The message belongs to a different account."
        }
    }
}

public enum RemoteOperationOutcome: Codable, Sendable, Equatable {
    /// The server is in the requested state. `verified`: read back afterwards.
    /// `alreadyInState`: it already was; no change was sent.
    case applied(verified: Bool, alreadyInState: Bool)
    /// Another client changed the message: nothing (more) was sent for it.
    case conflict(String)
    /// The request may or may not have taken effect; never repeated automatically.
    case uncertain(String)
    case rejected(RemoteRejection)

    public var name: String {
        switch self {
        case .applied: return "applied"
        case .conflict: return "conflict"
        case .uncertain: return "uncertain"
        case .rejected: return "rejected"
        }
    }
}

public enum RemoteAttemptState: Codable, Sendable, Equatable {
    /// Journalled; nothing sent.
    case planned
    /// The mutating request may have been sent (persisted BEFORE it is).
    case executing(since: Date)
    case finished(at: Date)
}

public struct RemoteOperation: Codable, Sendable, Equatable, Identifiable {
    public static let formatVersion = 1
    public var formatVersion = RemoteOperation.formatVersion
    public let id: UUID
    public let accountID: UUID
    public let provider: MailProviderKind
    public let identity: ProviderMessageIdentity
    /// The archive record of this message, when the operation came from it.
    public let emailID: UUID?
    public let request: RemoteChangeRequest
    public let expected: RemotePrecondition
    /// The cleanup plan this operation belongs to.
    public let planID: UUID?
    public var attempt: RemoteAttemptState
    public var outcome: RemoteOperationOutcome?
    /// The state read before the change (nil until read).
    public var observedBefore: RemoteItemState?
    /// The state read back afterwards (nil when it could not be read).
    public var observedAfter: RemoteItemState?
    /// IMAP: the message's identity in the destination after a move (COPYUID).
    /// Graph immutable ids and Gmail ids do not change.
    public var resultingIdentity: ProviderMessageIdentity?
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), accountID: UUID, identity: ProviderMessageIdentity, emailID: UUID? = nil,
                request: RemoteChangeRequest, expected: RemotePrecondition? = nil, planID: UUID? = nil, now: Date = Date()) {
        self.id = id; self.accountID = accountID; self.provider = identity.provider; self.identity = identity
        self.emailID = emailID; self.request = request; self.expected = expected ?? .implied(by: request)
        self.planID = planID; self.attempt = .planned; self.createdAt = now; self.updatedAt = now
    }

    public var isFinished: Bool { if case .finished = attempt { return true }; return false }
}
