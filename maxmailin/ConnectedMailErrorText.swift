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
        case let e as SelectiveListingStopped: return outcome(e.outcome)
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
        if isGmailPasswordRefusal(error, mailHost: mailHost) {
            log.error("Gmail refused the IMAP / SMTP password")
            return gmailAppPasswordRefused
        }
        return text(for: error)
    }

    /// The sentence only (tests; no log entry).
    static func sentence(for error: Error, mailHost: String?) -> String {
        isGmailPasswordRefusal(error, mailHost: mailHost) ? gmailAppPasswordRefused : sentence(for: error)
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

    // MARK: Sign-in

    private static func oauth(_ e: OAuthError) -> String {
        switch e {
        case .cancelled:
            return String(localized: "Sign-in was cancelled. Nothing was changed.")
        case .denied(let code, _) where code == "access_denied":
            return String(localized: "You did not allow mailin access at the provider, so nothing was changed.")
        case .denied:
            return String(localized: "The provider did not allow the sign-in. Nothing was changed.")
        case .reauthorisationNeeded:
            return String(localized: "This account's sign-in has expired or was withdrawn. Sign in again; saved mail remains available.")
        case .tokenEndpoint(let status, let error):
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
        case .permanent:
            return String(localized: "The mail server refused the request.")
        }
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
