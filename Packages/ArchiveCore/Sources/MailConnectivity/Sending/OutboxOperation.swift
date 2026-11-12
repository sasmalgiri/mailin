//
//  OutboxOperation.swift
//  MailConnectivity
//
//  Plan v4 V4-10 (§3 A12, §6 "Outbox and transport"): one durable send
//  operation. The old compose sheet built a fresh Message-ID on every attempt
//  and retried every error up to three times — after the server may already
//  have accepted the message. An `OutboxOperation` instead freezes, once:
//
//   • a stable operation ID and the composed Message-ID;
//   • the MIME bytes from `MIMEComposer` (stored beside the record, SHA-256
//     recorded and re-verified before every submission);
//   • the envelope (MAIL FROM, RCPT TO). Bcc recipients are in the envelope
//     only — never in the stored message's header. (The Gmail and Graph APIs
//     take their recipients from the MIME header, so for those routes a `Bcc:`
//     field is prepended to the SUBMITTED copy only; both providers remove it
//     before delivery. The stored bytes never carry it.)
//
//  State machine (persisted on every transition):
//
//      draft → queued → submitting → accepted → sentReconciled
//
//  with cancelledBeforeSubmission, rejected (known), retryWaiting, needsSignIn
//  and outcomeUncertain. `accepted` can only move on to `sentReconciled`: a
//  failed QUIT, a failed local write or a failed Sent copy never makes an
//  accepted message resendable. `outcomeUncertain` moves back to `queued`
//  only through an explicit user resend, after the provider's Sent folder
//  was checked (or could not be).
//

import Foundation

/// How the operation reaches the provider.
public enum OutboxRoute: Codable, Sendable, Equatable {
    /// Gmail users.messages.send — Gmail files the Sent copy itself.
    case gmailAPI
    /// Microsoft Graph sendMail (MIME) — Exchange files the Sent copy itself.
    case graphAPI
    /// Generic SMTP submission. `appendToSent`: the provider does NOT file a
    /// Sent copy, so one is APPENDed over IMAP as a separate step.
    case smtp(appendToSent: Bool)

    /// The provider creates the Sent copy itself: never append another.
    public var providerSavesSentCopy: Bool {
        switch self {
        case .gmailAPI, .graphAPI: return true
        case .smtp: return false
        }
    }

    /// The API routes read recipients from the MIME header.
    var recipientsFromHeader: Bool {
        if case .smtp = self { return false }
        return true
    }
}

/// How far a submission got — persisted BEFORE the step it names, so a
/// process killed at any instant knows whether the provider can have the message.
public enum SubmissionPhase: String, Codable, Sendable {
    /// Not yet connected, or still negotiating / sending the envelope.
    /// The provider cannot have accepted the message: a retry is safe.
    case notSubmitted
    /// The SMTP final dot, or the HTTP send request, may have reached the
    /// provider. Without its reply the outcome is unknown.
    case mayHaveReachedProvider
}

/// Where the provider's Sent copy stands — separate from acceptance.
public enum SentCopyState: Codable, Sendable, Equatable {
    /// Gmail / Graph file it themselves; nothing is appended.
    case providerFiles
    /// Generic SMTP without a Sent append (the server files it, or the user chose not to).
    case notRequested
    /// An IMAP APPEND to Sent is due.
    case appendPending
    case appended
    /// The APPEND failed; retrying appends again — it never resends the mail.
    case appendFailed(String)
}

/// What a check of the provider's Sent folder (by Message-ID) found.
public enum SentReconciliation: Codable, Sendable, Equatable {
    case notChecked
    case notFound(checkedAt: Date)
    case lookupFailed(String)
}

public enum SentConfirmation: String, Codable, Sendable {
    /// The provider's send response said the message is in Sent (Gmail SENT label).
    case providerResponse
    /// Found in the provider's Sent folder by Message-ID.
    case foundInSent
    /// The IMAP APPEND to Sent succeeded.
    case appendedToSent
}

public enum OutboxState: Codable, Sendable, Equatable {
    case draft
    case queued
    case submitting
    /// The provider accepted the message (SMTP 250 after DATA, Gmail 200, Graph
    /// 202 = accepted for processing). NOT recipient delivery.
    case accepted(at: Date, response: String)
    case sentReconciled(at: Date, how: SentConfirmation)
    case cancelledBeforeSubmission(at: Date)
    /// The provider refused the message or recipients; nothing was accepted.
    case rejected(reason: String, rejectedRecipients: [String])
    /// Known not accepted. `automatic`: retried when `notBefore` passes;
    /// otherwise the user must retry (e.g. the server offered no secure connection).
    case retryWaiting(reason: String, notBefore: Date, quota: Bool, automatic: Bool)
    case needsSignIn(reason: String)
    /// The provider may or may not have accepted it. Never resent automatically.
    case outcomeUncertain(reason: String, reconciliation: SentReconciliation)

    public var name: String {
        switch self {
        case .draft: return "draft"
        case .queued: return "queued"
        case .submitting: return "submitting"
        case .accepted: return "accepted"
        case .sentReconciled: return "sentReconciled"
        case .cancelledBeforeSubmission: return "cancelledBeforeSubmission"
        case .rejected: return "rejected"
        case .retryWaiting: return "retryWaiting"
        case .needsSignIn: return "needsSignIn"
        case .outcomeUncertain: return "outcomeUncertain"
        }
    }

    /// The provider has (or may have) the message: cancelling cannot recall it.
    public var isPastSubmission: Bool {
        switch self {
        case .submitting, .accepted, .sentReconciled, .outcomeUncertain: return true
        default: return false
        }
    }

    /// The provider is known to have accepted it.
    public var isAccepted: Bool {
        switch self {
        case .accepted, .sentReconciled: return true
        default: return false
        }
    }
}

public struct OutboxTransition: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var at: Date
    public var note: String?
}

public enum OutboxError: LocalizedError, Equatable {
    case illegalTransition(from: String, to: String)
    /// Cancel (Undo Send) only works before submission; there is no recall.
    case cannotCancelAfterSubmission(state: String)
    case notFound(UUID)
    case alreadyQueued(UUID)
    case composedForAnotherDraft
    case bccInHeader
    case messageNotCanonical(String)
    case messageDamaged(UUID)
    case resendNeedsReconciliation
    case notResendable(state: String)
    case newerFormat(Int)
    case corrupt(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .illegalTransition(let from, let to): return "A message cannot go from “\(from)” to “\(to)”."
        case .cannotCancelAfterSubmission: return "The message was already handed to the mail provider and cannot be recalled."
        case .notFound: return "The outbox item no longer exists."
        case .alreadyQueued: return "This version of the draft is already in the outbox."
        case .composedForAnotherDraft: return "The prepared message belongs to a different draft or version."
        case .bccInHeader: return "The prepared message shows Bcc recipients in its header and was not queued."
        case .messageNotCanonical(let why): return "The prepared message cannot be sent as it is: \(why)."
        case .messageDamaged: return "The stored copy of the prepared message is damaged."
        case .resendNeedsReconciliation: return "Check the provider's Sent folder before sending this message again."
        case .notResendable(let state): return "A message in state “\(state)” cannot be sent again."
        case .newerFormat(let v): return "This outbox item was saved by a newer version of mailin (format \(v))."
        case .corrupt(let why): return "An outbox item could not be read: \(why)."
        case .io(let why): return "The outbox could not be saved: \(why)"
        }
    }
}

public struct OutboxOperation: Codable, Sendable, Equatable, Identifiable {
    public static let formatVersion = 1

    public var formatVersion: Int = OutboxOperation.formatVersion
    // Frozen at enqueue.
    public let id: UUID
    public let accountID: UUID
    public let identityID: UUID
    public let draftID: UUID
    public let draftRevision: Int
    /// With angle brackets; identical on every attempt.
    public let messageID: String
    public let envelopeFrom: String
    /// To + Cc + Bcc (RCPT TO).
    public let envelopeRecipients: [String]
    /// The Bcc field written ONLY into an API submission (empty = none). Folded, without CRLF at the end.
    public let apiBccHeader: String?
    public let requiresSMTPUTF8: Bool
    public let messageSHA256: String
    public let messageSize: Int
    public let route: OutboxRoute
    public let createdAt: Date
    // Changing.
    public private(set) var state: OutboxState
    /// Undo Send: not submitted before this instant (persisted, survives restart).
    public internal(set) var notBefore: Date?
    public internal(set) var phase: SubmissionPhase
    public internal(set) var submissionAttempts: Int
    public internal(set) var sentCopy: SentCopyState
    /// Gmail message id / SMTP queue reply / Graph request id, when known.
    public internal(set) var providerReference: String?
    public private(set) var history: [OutboxTransition]
    /// Times the user explicitly chose to send again after an uncertain outcome.
    public internal(set) var userResends: Int

    init(id: UUID, composed: ComposedMessage, apiBccHeader: String?, route: OutboxRoute, createdAt: Date, notBefore: Date?) {
        self.id = id
        accountID = composed.accountID; identityID = composed.identityID
        draftID = composed.draftID; draftRevision = composed.draftRevision
        messageID = composed.messageID; envelopeFrom = composed.envelopeFrom; envelopeRecipients = composed.envelopeRecipients
        self.apiBccHeader = apiBccHeader
        requiresSMTPUTF8 = composed.requiresSMTPUTF8
        messageSHA256 = composed.sha256; messageSize = composed.bytes.count
        self.route = route; self.createdAt = createdAt
        state = .draft; self.notBefore = notBefore; phase = .notSubmitted; submissionAttempts = 0
        sentCopy = route.providerSavesSentCopy ? .providerFiles : (route == .smtp(appendToSent: true) ? .appendPending : .notRequested)
        providerReference = nil; history = []; userResends = 0
    }

    /// The only way the state changes; illegal moves throw.
    mutating func move(to next: OutboxState, at date: Date, note: String? = nil) throws {
        guard Self.allowed(from: state, to: next) else { throw OutboxError.illegalTransition(from: state.name, to: next.name) }
        history.append(OutboxTransition(from: state.name, to: next.name, at: date, note: note))
        state = next
    }

    static func allowed(from: OutboxState, to: OutboxState) -> Bool {
        switch (from, to) {
        case (.draft, .queued), (.draft, .cancelledBeforeSubmission): return true
        case (.queued, .submitting), (.queued, .cancelledBeforeSubmission): return true
        // Found before any connection (no submitter, damaged stored copy).
        case (.queued, .retryWaiting), (.queued, .rejected), (.queued, .needsSignIn): return true
        case (.submitting, .accepted), (.submitting, .rejected), (.submitting, .retryWaiting),
             (.submitting, .needsSignIn), (.submitting, .outcomeUncertain): return true
        // Accepted moves forward only.
        case (.accepted, .sentReconciled): return true
        case (.retryWaiting, .queued), (.retryWaiting, .cancelledBeforeSubmission): return true
        case (.needsSignIn, .queued), (.needsSignIn, .cancelledBeforeSubmission): return true
        // Found in Sent; a recorded check; or the user's explicit resend.
        case (.outcomeUncertain, .sentReconciled), (.outcomeUncertain, .outcomeUncertain), (.outcomeUncertain, .queued): return true
        default: return false
        }
    }

    /// The bytes handed to the provider. SMTP: the stored message as it is.
    /// Gmail / Graph: the stored message with the Bcc field prepended (their
    /// APIs read recipients from the header and remove Bcc before delivery).
    public func submissionBytes(stored: Data) -> Data {
        guard route.recipientsFromHeader, let bcc = apiBccHeader else { return stored }
        var out = Data((bcc + "\r\n").utf8)
        out.append(stored)
        return out
    }
}
