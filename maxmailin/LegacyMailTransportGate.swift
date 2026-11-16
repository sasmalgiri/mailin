//
//  LegacyMailTransportGate.swift
//  maxmailin
//
//  Rule 7 (review 2026-11-16). The pre-4.0 connectors (GmailConnector,
//  OutlookConnector, IMAPClient, SMTPClient) are switched off — no view, menu
//  or intent reaches them — but a connected build compiles them, so every
//  socket or request they would open asks the mail policy first. They have no
//  account in the policy (the 4.0 engines own every connected account), so
//  the policy refuses them and counts the refusal in Health; nothing of theirs
//  reaches the network. Rule 14: switched off, not ripped out.
//
//  The decisions here compile in every edition (no network code), so the
//  tests can check them in any build; the request helper below exists only
//  where the transports do.
//

import Foundation

enum LegacyMailTransportGate {
    static func permit(host: String, destination: MailNetworkDestination = .mailServer,
                       operation: MailNetworkOperation, purpose: MailAccountMode = .preserveMail,
                       policy: MailNetworkPolicy = .shared) throws {
        try policy.permit(MailNetworkRequest(accountID: nil, host: host, destination: destination,
                                             operation: operation, purpose: purpose))
    }
}

/// The legacy SMTP client's security and retry rules (rule 7, review 2026-11-16).
enum LegacySMTPRules {
    enum SecurityStep: Equatable { case implicitTLS, startTLS }

    enum Failure: LocalizedError, Equatable {
        /// Neither implicit TLS nor STARTTLS: the password is never sent in the clear.
        case plaintextRefused
        /// The message went to the server but its answer never arrived: it may
        /// have been sent. Never retried automatically.
        case outcomeUncertain(String)

        var errorDescription: String? {
            switch self {
            case .plaintextRefused:
                return "The server offers no encrypted connection (TLS or STARTTLS); mailin does not send a password in the clear."
            case .outcomeUncertain(let why):
                return "The server's answer to the message never arrived (\(why)); it may have been sent. Check the Sent folder before sending again."
            }
        }
    }

    /// Authentication happens only over TLS — implicit (port 465) or after
    /// STARTTLS. A server that offers neither is refused; there is no
    /// plaintext AUTH fallback. EHLO lines look like "250-STARTTLS".
    static func securityStep(useSSL: Bool, capabilities: [String]) throws -> SecurityStep {
        if useSSL { return .implicitTLS }
        let offersStartTLS = capabilities.contains { line in
            line.dropFirst(4).trimmingCharacters(in: .whitespaces).uppercased() == "STARTTLS"
        }
        guard offersStartTLS else { throw Failure.plaintextRefused }
        return .startTLS
    }

    /// Only a failure before the message went out is retried. "May have been
    /// sent", a mail-policy refusal and a server without TLS are final — a
    /// retry would send the message twice or ask again for what was refused.
    static func mayRetry(after error: Error) -> Bool {
        if error is MailNetworkRefusal { return false }
        if error is Failure { return false }
        return true
    }
}

#if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
extension LegacyMailTransportGate {
    /// `URLSession.shared.data(for:)` behind the policy.
    static func data(for request: URLRequest, destination: MailNetworkDestination = .mailServer,
                     operation: MailNetworkOperation = .request,
                     policy: MailNetworkPolicy = .shared) async throws -> (Data, URLResponse) {
        try permit(host: request.url?.host ?? "", destination: destination, operation: operation, policy: policy)
        return try await URLSession.shared.data(for: request)
    }
}
#endif
