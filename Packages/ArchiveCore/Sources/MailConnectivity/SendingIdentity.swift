//
//  SendingIdentity.swift
//  MailConnectivity
//
//  Plan v4 V4-09 / T34 (§6 "Replying to an old archive does not authorise
//  sending as its former owner"): a draft names its account AND one sending
//  identity (the account's own address or a provider-verified alias). The
//  identity is a required, explicit choice — it is never inferred from the
//  archived message's recipients or the archive's former owner. Composition
//  needs an `AuthorisedSender`, which only `SenderAuthorisation.authorise`
//  can make, and only when the identity belongs to the draft's account, is
//  permitted, and the account is enabled for sending.
//

import Foundation

public struct SendingIdentity: Codable, Sendable, Equatable, Identifiable {
    public enum Permission: String, Codable, Sendable {
        /// The account's own address, or an alias the provider has verified (Gmail send-as, Graph proxy address, IMAP/SMTP configured address).
        case verified
        /// Listed by the provider but not (yet) verified for sending.
        case unverified
        /// Once permitted, now withdrawn.
        case revoked
    }

    public let id: UUID
    public let accountID: UUID
    public var address: MailAddress
    public var permission: Permission
    /// The identity's own Reply-To, written on drafts sent from it (empty = none).
    public var replyTo: [MailAddress]

    public init(id: UUID = UUID(), accountID: UUID, address: MailAddress, permission: Permission = .verified, replyTo: [MailAddress] = []) {
        self.id = id; self.accountID = accountID; self.address = address; self.permission = permission; self.replyTo = replyTo
    }

    /// The account's primary identity, from its display address.
    public static func primary(for account: MailAccount, displayName: String? = nil) throws -> SendingIdentity {
        var address = try MailAddress(parsing: account.displayIdentity)
        if let displayName { address.displayName = displayName }
        return SendingIdentity(accountID: account.id, address: address, permission: .verified)
    }
}

/// Proof that a draft may be composed as a given identity. Only
/// `SenderAuthorisation` can make one.
public struct AuthorisedSender: Sendable, Equatable {
    public let accountID: UUID
    public let identity: SendingIdentity
    public let draftID: UUID
    public let draftRevision: Int

    fileprivate init(accountID: UUID, identity: SendingIdentity, draftID: UUID, draftRevision: Int) {
        self.accountID = accountID; self.identity = identity; self.draftID = draftID; self.draftRevision = draftRevision
    }
}

public enum SenderAuthorisationError: LocalizedError, Equatable {
    /// No sending identity was chosen (a reply from an old archive starts here).
    case noIdentityChosen
    case accountMismatch(draftAccount: UUID, givenAccount: UUID)
    case unknownIdentity(UUID)
    case identityBelongsToAnotherAccount(identity: UUID, identityAccount: UUID, draftAccount: UUID)
    case identityNotPermitted(address: String, permission: SendingIdentity.Permission)
    case accountCannotSend(String)

    public var errorDescription: String? {
        switch self {
        case .noIdentityChosen: return "Choose which of your connected addresses this message is sent from."
        case .accountMismatch: return "This draft belongs to a different account."
        case .unknownIdentity: return "The chosen sending address is no longer available for this account."
        case .identityBelongsToAnotherAccount: return "The chosen sending address belongs to a different account."
        case .identityNotPermitted(let address, let permission): return "\(address) is not permitted for sending (\(permission.rawValue))."
        case .accountCannotSend(let why): return "This account cannot send: \(why)."
        }
    }
}

public enum SenderAuthorisation {
    /// Checks, in order: the account is the draft's account; the account is
    /// enabled for sending and not removed; an identity was chosen; it exists
    /// in the account's identity list; it belongs to this account; it is verified.
    public static func authorise(_ draft: Draft, account: MailAccount, identities: [SendingIdentity]) throws -> AuthorisedSender {
        guard account.id == draft.accountID else {
            throw SenderAuthorisationError.accountMismatch(draftAccount: draft.accountID, givenAccount: account.id)
        }
        guard account.connectionState != .removed else { throw SenderAuthorisationError.accountCannotSend("it was removed") }
        guard account.enabledModes.contains(.send) else { throw SenderAuthorisationError.accountCannotSend("sending is not turned on for it") }
        guard let chosen = draft.senderIdentityID else { throw SenderAuthorisationError.noIdentityChosen }
        guard let identity = identities.first(where: { $0.id == chosen }) else { throw SenderAuthorisationError.unknownIdentity(chosen) }
        guard identity.accountID == draft.accountID else {
            throw SenderAuthorisationError.identityBelongsToAnotherAccount(identity: identity.id, identityAccount: identity.accountID, draftAccount: draft.accountID)
        }
        guard identity.permission == .verified else {
            throw SenderAuthorisationError.identityNotPermitted(address: identity.address.addrSpec, permission: identity.permission)
        }
        return AuthorisedSender(accountID: account.id, identity: identity, draftID: draft.id, draftRevision: draft.revision)
    }
}
