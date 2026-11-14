@testable import ArchiveCore
import MailConnectivity
//
//  ConnectedMailErrorText.swift
//  maxmailin
//
//  Release audit 2026-11-13: what connected mail shows when something fails.
//  Every error a person can meet on the Mail page (sign-in, the Keychain, the
//  provider, the network policy, the network itself) becomes one localised
//  sentence that says what happened and what to do. It never shows an
//  OSStatus number, an HTTP body, an account UUID or an enum's debug form;
//  the technical detail goes to the log instead.
//

import Foundation
import os
import Security

enum ConnectedMailErrorText {
    private static let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "ConnectedMail")

    /// The sentence for `error`. Logs the technical detail.
    static func text(for error: Error) -> String {
        log.error("connected mail error \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)")
        return sentence(for: error)
    }

    /// The sentence only (tests; no log entry).
    static func sentence(for error: Error) -> String {
        if let coded = codedSentence(for: error, mailHost: nil) { return coded }
        switch error {
        case let e as OAuthError: return oauth(e)
        case let e as CredentialStoreError: return keychain(e)
        case let e as MailProviderError: return provider(e)
        case let e as MailNetworkRefusal: return e.explanation
        case is GmailAdapterError: return MailServerChangeText.rejection(.networkNotPermitted(""))
        case let e as URLError: return network(e)
        case let e as IMAPTransportError: return imap(e)
        case is GraphConfigurationError, is GmailOAuth.ConfigurationError:
            return String(localized: "Sign-in for this provider is not set up in this build.")
        case let e as SenderAuthorisationError: return sender(e)
        case let e as SelectiveListingStopped:
            if case .failed = e.outcome, let cause = e.cause { return sentence(for: cause.error) }
            return outcome(e.outcome)
        case is CancellationError: return String(localized: "Stopped before it finished. Nothing was lost.")
        // The app's own errors already carry a localised sentence.
        case let e as MailWorkspaceError: return e.text
        case let e as MailBackendUnavailable: return e.errorDescription ?? fallback
        case let e as ConnectedRecipeError: return e.errorDescription ?? fallback
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { return network(URLError(URLError.Code(rawValue: ns.code))) }
            if ns.domain == NSOSStatusErrorDomain { return keychainStatus(OSStatus(truncatingIfNeeded: ns.code), saving: false) }
            let text = error.localizedDescription
            return isPresentable(text) ? text : fallback
        }
    }

    // MARK: Gmail over IMAP (V4-16)

    /// The sentence for `error` from the account whose mail server is
    /// `mailHost`: Gmail's IMAP / SMTP refusing the password (IMAP
    /// AUTHENTICATIONFAILED, SMTP 535) means it needs an app password.
    static func text(for error: Error, mailHost: String?) -> String {
        if let coded = codedSentence(for: error, mailHost: mailHost) {
            log.error("connected mail error \(String(describing: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)")
            return coded
        }
        if isGmailPasswordRefusal(error, mailHost: mailHost) {
            log.error("Gmail refused the IMAP / SMTP password")
            return gmailAppPasswordRefused
        }
        return text(for: error)
    }

    /// The sentence only (tests; no log entry).
    static func sentence(for error: Error, mailHost: String?) -> String {
        if let coded = codedSentence(for: error, mailHost: mailHost) { return coded }
        return isGmailPasswordRefusal(error, mailHost: mailHost) ? gmailAppPasswordRefused : sentence(for: error)
    }

    static func isGmailHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return false }
        return IMAPProviderPreset.gmailHosts.contains(host)
    }

    static func isGmailPasswordRefusal(_ error: Error, mailHost: String?) -> Bool {
        guard isGmailHost(mailHost) else { return false }
        switch error {
        case MailProviderError.reauthorisationRequired, MailProviderError.unauthorized: return true
        case let e as SelectiveListingStopped: if case .needsSignIn = e.outcome { return true }; return false
        default: return false
        }
    }

    /// Gmail refused the password: what to do.
    static var gmailAppPasswordRefused: String {
        String(localized: "Google refused the password. Gmail needs an app password here: turn on 2-Step Verification, create an app password at myaccount.google.com/apppasswords and paste the 16-character password. A normal Google password will be refused. Saved mail remains available.")
    }

    static var fallback: String {
        String(localized: "Something went wrong with this mail account. Saved mail is not affected; the details are in the app's log.")
    }

    // MARK: IMAP / SMTP refusals (audit 2026-11-14)

    /// The sentence for an IMAP / SMTP error carrying an `IMAPErrorCode`
    /// (a coded `MailProviderError`, a login-check refusal, a stopped
    /// listing); nil when it carries none.
    static func codedSentence(for error: Error, mailHost: String?, retrying: Bool = true) -> String? {
        switch error {
        case let e as AccountLoginCheckError:
            switch e {
            case .incoming(let why), .outgoing(let why): return codedSentence(why, mailHost: mailHost, retrying: false)
            }
        case let e as SelectiveListingStopped:
            guard case .failed = e.outcome, let cause = e.cause else { return nil }
            return codedSentence(for: cause.error, mailHost: mailHost, retrying: retrying)
        case let e as IMAPTLSError:
            return codedSentence(for: e.providerError, mailHost: mailHost ?? e.host, retrying: retrying)
        case MailProviderError.permanent(let why), MailProviderError.transient(let why):
            return codedSentence(why, mailHost: mailHost, retrying: retrying)
        default:
            return nil
        }
    }

    /// The sentence for a reason that starts with an `IMAPErrorCode`
    /// ("<code>: <server's words>"); nil for an uncoded reason. `mailHost`
    /// is the account's server (provider-specific advice; the certificate's
    /// host when the reason does not name it). `retrying` false: nothing
    /// tries again by itself (the login check before saving).
    static func codedSentence(_ reason: String, mailHost: String?, retrying: Bool = true) -> String? {
        guard let code = IMAPErrorCode.code(in: reason) else { return nil }
        let typedHost = mailHost?.trimmingCharacters(in: .whitespaces)
        let host = tlsHost(in: IMAPErrorCode.detail(in: reason)) ?? (typedHost?.isEmpty == false ? typedHost : nil)
        switch code {
        case IMAPErrorCode.imapDisabled:
            return imapAccessOff
        case IMAPErrorCode.webLoginRequired:
            return String(localized: "The provider wants you to sign in once on its website first. Sign in there in a web browser, then try again. Saved mail remains available.")
        case IMAPErrorCode.appPasswordRequired:
            return appPasswordNeeded(mailHost: mailHost)
        case IMAPErrorCode.tooManyConnections:
            return retrying
                ? String(localized: "The mail server has too many connections open for this account right now. mailin tries again by itself; closing mail apps on other devices helps.")
                : String(localized: "The mail server has too many connections open for this account right now. Close mail apps on other devices or wait a few minutes, then try again.")
        case IMAPErrorCode.authenticationFailed:
            return isGmailHost(mailHost) ? gmailAppPasswordRefused : imapPasswordRefused
        case IMAPErrorCode.certificateNotTrusted, IMAPErrorCode.smtpCertificateNotTrusted:
            if let host {
                return String(localized: "The mail server's certificate is not trusted for \(host), so mailin does not connect to it and no password was sent.")
            }
            return String(localized: "The mail server's certificate is not trusted, so mailin does not connect to it and no password was sent.")
        case IMAPErrorCode.tlsHandshakeFailed, IMAPErrorCode.smtpTLSHandshakeFailed:
            if let host {
                return String(localized: "A secure connection to \(host) could not be made, so mailin did not connect and no password was sent. Check the server name, port and security setting.")
            }
            return String(localized: "A secure connection to the mail server could not be made, so mailin did not connect and no password was sent. Check the server name, port and security setting.")
        case IMAPErrorCode.gmailAllMailHidden:
            return gmailAllMailHidden
        default:
            return nil
        }
    }

    /// The host a TLS refusal names ("the certificate of <host> is not
    /// trusted", "a secure connection to <host> could not be established").
    static func tlsHost(in detail: String) -> String? {
        let pattern = #"(?:certificate of|secure connection to) (\S+) (?:is not trusted|could not be established)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              let range = Range(match.range(at: 1), in: detail) else { return nil }
        return String(detail[range])
    }

    static var imapAccessOff: String {
        String(localized: "IMAP access is turned off for this account. Turn on IMAP in the provider's mail settings; for a work or school account (such as Google Workspace) an administrator must allow IMAP. Saved mail remains available.")
    }

    /// The mail server refused the password of an IMAP account (not Gmail).
    static var imapPasswordRefused: String {
        String(localized: "The mail server refused the password. Choose Replace password… to enter the current password or app password. Saved mail remains available.")
    }

    static func isICloudHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return false }
        return host == "mail.me.com" || host.hasSuffix(".mail.me.com")
    }

    /// The server wants an app password, by provider.
    static func appPasswordNeeded(mailHost: String?) -> String {
        if isGmailHost(mailHost) {
            return String(localized: "This Google account needs an app password, not the normal password: turn on 2-Step Verification, create an app password at myaccount.google.com/apppasswords and use it as the password in mailin.")
        }
        if isICloudHost(mailHost) {
            return String(localized: "This iCloud account needs an app-specific password: create one at account.apple.com under Sign-In and Security ▸ App-Specific Passwords and use it as the password in mailin.")
        }
        return String(localized: "This account needs an app password (an app-specific password) instead of the normal password. Create one in the provider's account security settings and use it as the password in mailin.")
    }

    /// Gmail's All Mail hidden from IMAP: what cannot be saved, and the fix (rule 6).
    static var gmailAllMailHidden: String {
        String(localized: "All Mail is hidden from IMAP in Gmail settings; archived mail without a label cannot be saved. Turn on 'Show in IMAP' for All Mail.")
    }

    /// The stated limits of an account's last folder listing, one sentence each.
    static func listingLimits(_ limits: [IMAPListingLimit]) -> [String] {
        limits.compactMap { codedSentence($0.code, mailHost: nil) }
    }

    /// The failure codes after which a password account offers Replace password….
    static let replacePasswordCodes: Set<String> = [IMAPErrorCode.appPasswordRequired, IMAPErrorCode.authenticationFailed]

    // MARK: Sign-in

    /// Microsoft's sign-in refusals that need someone else (an administrator)
    /// or another step, by AADSTS code / OAuth error. Never shows the code.
    static func microsoftRefusal(error: String?, description: String?) -> String? {
        switch microsoftRefusalCode(description) {
        case 65001?, 90094?, 90095?:
            return microsoftAdminApprovalNeeded
        case let code? where (53000...53003).contains(code):
            return String(localized: "Your organisation's sign-in rules blocked this sign-in, for example from this device or network. Ask your IT administrator, or sign in from a device your organisation allows. Nothing was changed.")
        case 50076?, 50079?:
            return String(localized: "Microsoft needs extra verification for this account. Sign in again and complete the verification step Microsoft shows. Nothing was changed.")
        case 700016?:
            return String(localized: "mailin is not available in your organisation's Microsoft directory. Ask your IT administrator to allow mailin, or sign in with another account. Nothing was changed.")
        case 50020?:
            return String(localized: "This account is not part of the organisation it tried to sign in to. Sign in with an account of that organisation, or with a personal Microsoft account. Nothing was changed.")
        default:
            return error == "consent_required" ? microsoftAdminApprovalNeeded : nil
        }
    }

    static var microsoftAdminApprovalNeeded: String {
        String(localized: "Your organisation's administrator must approve mailin before this account can sign in. Ask your IT administrator to approve mailin, then sign in again. Nothing was changed.")
    }

    private static func oauth(_ e: OAuthError) -> String {
        switch e {
        case .cancelled:
            return String(localized: "Sign-in was cancelled. Nothing was changed.")
        case .denied(let code, let description) where microsoftRefusal(error: code, description: description) != nil:
            return microsoftRefusal(error: code, description: description) ?? fallback
        case .denied(let code, _) where code == "access_denied":
            return String(localized: "You did not allow mailin access at the provider, so nothing was changed.")
        case .denied:
            return String(localized: "The provider did not allow the sign-in. Nothing was changed.")
        case .reauthorisationNeeded:
            return String(localized: "This account's sign-in has expired or was withdrawn. Sign in again; saved mail remains available.")
        case .tokenEndpoint(let status, let error, let description):
            if let refusal = microsoftRefusal(error: error, description: description) { return refusal }
            if let error, ["invalid_grant", "interaction_required", "consent_required", "login_required"].contains(error) {
                return String(localized: "This account's sign-in has expired or was withdrawn. Sign in again; saved mail remains available.")
            }
            return http(status) ?? String(localized: "The provider refused the sign-in. Try again in a few minutes.")
        case .stateMismatch, .callbackMismatch, .missingCode, .noPendingAuthorization, .invalidTokenResponse:
            return String(localized: "The provider's sign-in answer could not be used. Try signing in again.")
        case .notRegistered:
            return String(localized: "Sign-in for this provider is not set up in this build.")
        case .credentialReadFailed:
            return String(localized: "The account's sign-in could not be read from the Keychain on this device. Unlock the device and try again.")
        case .credentialSaveFailed:
            return String(localized: "The sign-in worked, but it could not be saved in the Keychain on this device. Nothing was changed; try again.")
        case .wrongAccount, .audienceMismatch:
            return String(localized: "A saved sign-in belongs to another account and was not used. Sign in again.")
        case .randomGenerationFailed:
            return String(localized: "Sign-in could not start on this device. Try again.")
        }
    }

    // MARK: Keychain

    private static func keychain(_ e: CredentialStoreError) -> String {
        switch e {
        case .keychain(let operation, let status): return keychainStatus(status, saving: operation != "read")
        case .unexpectedData:
            return String(localized: "The account's sign-in could not be read from the Keychain on this device. Unlock the device and try again.")
        }
    }

    private static func keychainStatus(_ status: OSStatus, saving: Bool) -> String {
        switch status {
        case errSecMissingEntitlement:
            return String(localized: "This copy of mailin is not allowed to keep sign-ins in the Keychain. Install mailin from the App Store or TestFlight and sign in again.")
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return String(localized: "The Keychain is locked. Unlock the device and try again.")
        default:
            return saving
                ? String(localized: "The sign-in worked, but it could not be saved in the Keychain on this device. Nothing was changed; try again.")
                : String(localized: "The account's sign-in could not be read from the Keychain on this device. Unlock the device and try again.")
        }
    }

    // MARK: Provider and network

    private static func provider(_ e: MailProviderError) -> String {
        switch e {
        case .rateLimited:
            return String(localized: "The provider asked mailin to slow down. mailin tries again by itself.")
        case .quotaExceeded:
            return String(localized: "The provider's limit for this account was reached. mailin tries again by itself later.")
        case .transient:
            return String(localized: "The mail server did not answer properly. Try again in a few minutes.")
        case .unauthorized, .reauthorisationRequired:
            return String(localized: "This account's sign-in has expired or was withdrawn. Sign in again; saved mail remains available.")
        case .itemUnavailable:
            return String(localized: "The message is no longer on the server.")
        case .changeTokenExpired:
            return String(localized: "The server's list of changes expired; the next sync lists the mailbox again.")
        case .folderUnavailable:
            return String(localized: "A folder is no longer on the server.")
        case .permanent(let reason) where reason.hasPrefix(GraphAdapter.noMailboxPrefix):
            return String(localized: "This Microsoft account has no Outlook mailbox — it signs in with another provider's address. Add an Outlook.com address to the account at account.microsoft.com, or connect that other mailbox directly.")
        case .permanent(let reason) where reason.hasPrefix(GraphAdapter.mailboxAccessDeniedPrefix):
            return String(localized: "This account is not allowed to read that mailbox. The mailbox owner or an administrator must give it access. Saved mail remains available.")
        case .permanent:
            return String(localized: "The mail server refused the request.")
        }
    }

    // MARK: Capture status (audit 2026-11-14)

    /// The headline of a capture that stopped: the typed cause's sentence,
    /// never the provider's raw text (codes, HTTP statuses, enum names).
    static func stoppedHeadline(_ why: String, cause: SyncFailureCause?, mailHost: String? = nil) -> String {
        let reason = cause.map { sentence(for: $0.error, mailHost: mailHost) }
            ?? codedSentence(why, mailHost: mailHost)
            ?? (isPresentable(why) ? why : fallback)
        return String(localized: "Last capture stopped; saved mail remains available. \(reason)")
    }

    // MARK: Outbox (audit 2026-11-14)

    /// The sentence for a message over Microsoft's 4 MB send limit.
    static func graphMessageTooLarge(encodedBytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(encodedBytes), countStyle: .binary)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(GraphSendSubmitter.maxEncodedBytes), countStyle: .binary)
        return String(localized: "Not sent: this message is \(size) once prepared for sending, and Microsoft accepts at most \(limit) per message sent from mailin. Remove or shrink attachments and send it again.")
    }

    /// The sentence for a `.rejected` outbox reason the app words itself;
    /// nil for a reason without special wording.
    static func outboxRejection(_ reason: String) -> String? {
        if let encoded = GraphSendSubmitter.tooLargeEncodedBytes(inReason: reason) { return graphMessageTooLarge(encodedBytes: encoded) }
        return codedSentence(reason, mailHost: nil).map { String(localized: "Not sent. \($0)") }
    }

    /// The sentence for a `.retryWaiting` outbox reason the app words itself
    /// (SMTP certificate / TLS refusals); nil for a reason without special wording.
    static func outboxRetry(_ reason: String) -> String? {
        codedSentence(reason, mailHost: nil).map { String(localized: "Not sent yet. \($0)") }
    }

    /// The pre-queue check: the sentence when `messageBytes` cannot be sent
    /// through Microsoft Graph, nil when it fits.
    static func graphSizeRefusal(messageBytes: Int) -> String? {
        guard case .tooLarge(let encoded) = GraphSendSubmitter.sizeCheck(messageBytes: messageBytes) else { return nil }
        return graphMessageTooLarge(encodedBytes: encoded)
    }

    /// The sentence for an HTTP status a provider answered with (nil = no special wording).
    static func http(_ status: Int) -> String? {
        switch status {
        case 401: return String(localized: "This account's sign-in has expired or was withdrawn. Sign in again; saved mail remains available.")
        case 403: return String(localized: "The provider refused this request for this account.")
        case 429: return String(localized: "The provider asked mailin to slow down. mailin tries again by itself.")
        case 500...599: return String(localized: "The mail server did not answer properly. Try again in a few minutes.")
        default: return nil
        }
    }

    private static func network(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return String(localized: "This device is offline. Connect to the internet and try again.")
        case .timedOut:
            return String(localized: "The mail server took too long to answer. Try again in a few minutes.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return String(localized: "The mail server could not be reached. Check the connection and try again.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return String(localized: "A secure connection to the mail server could not be made.")
        case .cancelled:
            return String(localized: "Stopped before it finished. Nothing was lost.")
        default:
            return String(localized: "The mail server could not be reached. Check the connection and try again.")
        }
    }

    private static func imap(_ e: IMAPTransportError) -> String {
        switch e {
        case .timedOut: return String(localized: "The mail server took too long to answer. Try again in a few minutes.")
        case .plaintextRefused, .tlsUpgradeUnavailable: return String(localized: "A secure connection to the mail server could not be made.")
        case .connectionFailed, .closed: return String(localized: "The mail server could not be reached. Check the connection and try again.")
        }
    }

    private static func sender(_ e: SenderAuthorisationError) -> String {
        switch e {
        case .noIdentityChosen: return MailComposeGate.text(.noIdentity)
        case .accountCannotSend: return MailComposeGate.text(.sendingOff)
        case .accountMismatch, .unknownIdentity, .identityBelongsToAnotherAccount, .identityNotPermitted:
            return MailComposeGate.text(.identityNotOfAccount)
        }
    }

    private static func outcome(_ o: SyncOutcome) -> String {
        switch o {
        case .needsSignIn: return oauth(.reauthorisationNeeded(UUID()))
        case .paused(.rateLimited): return provider(.rateLimited(retryAfter: nil))
        case .paused(.quotaExceeded): return provider(.quotaExceeded(resetAfter: nil))
        case .paused(.diskFull): return String(localized: "Capture paused: not enough free space")
        case .paused(.driveUnavailable): return String(localized: "Capture paused: drive unavailable")
        case .notPermitted(let why): return isPresentable(why) ? why : MailServerChangeText.rejection(.networkNotPermitted(""))
        case .cancelled, .aborted: return String(localized: "Stopped before it finished. Nothing was lost.")
        case .failed(let why): return isPresentable(why) ? why : fallback
        case .alreadyRunning: return String(localized: "Mail is already being saved for this account.")
        case .completed, .completedWithFailures: return fallback
        }
    }

    // MARK: Screening

    /// False for text that carries technical detail a person cannot act on:
    /// an account UUID, an OSStatus / error code, an HTTP status or body, a
    /// Foundation error dump or an enum's debug form.
    static func isPresentable(_ text: String) -> Bool {
        let patterns = [
            #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,   // UUID
            #"OSStatus|Error Domain=|NSError|NSURLError|errSec"#,
            #"\(-?\d{2,}\)"#,                                    // "(-34018)", "(401)"
            #"\bHTTP\s*\d{3}\b"#,
            #"[{}\[\]]|\"error\""#,                              // JSON bodies
            #"\b[a-z]+[A-Z]\w*\("#,                              // enum dumps: rateLimited(…), keychain(…)
        ]
        return !patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
