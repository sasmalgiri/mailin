//
//  MessageSubmitter.swift
//  MailConnectivity
//
//  Plan v4 V4-10: the contract each send route implements (SMTP, Gmail API,
//  Graph), the separate Sent-copy step, and the Sent lookup used to
//  reconcile an uncertain outcome. A submitter makes ONE submission per
//  call — no hidden retries — and must call `checkpoint(.mayHaveReachedProvider)`
//  immediately before the step after which the provider can have the
//  message (the SMTP final dot, the HTTP send request). If the checkpoint
//  throws (it could not be made durable), the submitter stops without that step.
//

import Foundation

/// One frozen message, as handed to a submitter.
public struct OutboundMessage: Sendable, Equatable {
    public let operationID: UUID
    public let accountID: UUID
    public let messageID: String
    public let envelopeFrom: String
    public let envelopeRecipients: [String]
    public let requiresSMTPUTF8: Bool
    /// The exact bytes to submit (see `OutboxOperation.submissionBytes`).
    public let bytes: Data
}

public enum SubmissionOutcome: Sendable, Equatable {
    /// Accepted by the provider (not delivered). `savedToSent`: the response
    /// itself confirms the provider's Sent copy (Gmail's SENT label).
    case accepted(response: String, providerReference: String?, savedToSent: Bool)
    /// Known not accepted; will not succeed by retrying.
    case rejected(reason: String, rejectedRecipients: [String])
    /// Known not accepted; may succeed later. `automatic == false`: only the user retries.
    case retry(reason: String, after: TimeInterval?, quota: Bool, automatic: Bool)
    case needsSignIn(reason: String)
    /// Reached the provider without a reply: it may have been accepted.
    case uncertain(reason: String)
}

public typealias SubmissionCheckpoint = @Sendable (SubmissionPhase) async throws -> Void

public protocol MessageSubmitter: Sendable {
    func submit(_ message: OutboundMessage, checkpoint: @escaping SubmissionCheckpoint) async -> SubmissionOutcome
}

/// Generic SMTP accounts: an IMAP APPEND of the sent message to the Sent
/// folder, run only AFTER acceptance. Its failure never resends the mail.
public protocol SentFolderAppender: Sendable {
    /// The host asked for in the network permission.
    var host: String { get }
    func appendToSent(_ bytes: Data, messageID: String, accountID: UUID) async throws
}

public enum SentLookupResult: Sendable, Equatable {
    case found(providerReference: String?)
    case notFound
}

/// The provider's Sent folder searched by Message-ID (Gmail `rfc822msgid:`,
/// Graph `internetMessageId`, IMAP `SEARCH HEADER Message-ID`).
public protocol SentMessageLookup: Sendable {
    var host: String { get }
    func findSent(messageID: String, accountID: UUID) async throws -> SentLookupResult
}

/// Raised by a transport when it KNOWS the request never left the device
/// (no route, DNS failure, connection refused, permission refused).
public struct NotSentError: Error, Sendable, Equatable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

extension URLError {
    /// Failures that happen before any request byte can reach the server.
    var certainlyNotSent: Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }
}
