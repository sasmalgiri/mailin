@testable import ArchiveCore
import MailConnectivity
//
//  MailLifecycleText.swift
//  maxmailin
//
//  Lifecycle audit 2026-11-14: the sentences connected mail shows after a
//  restore, on removal, re-adding, re-signing in, password replacement,
//  sending limits and search-index failures. One place, translated.
//

import Foundation

enum MailLifecycleText {

    // MARK: Restore

    /// What the restore did to connected mail (empty when there was nothing).
    static func restoreReport(_ r: ConnectedRestoreReport) -> String {
        var parts: [String] = []
        if !r.accountsNeedingSignIn.isEmpty {
            parts.append(String(localized: "\(r.accountsNeedingSignIn.count) connected accounts must sign in again before anything connects for them."))
        }
        if !r.outboxHeldForDecision.isEmpty {
            parts.append(String(localized: "\(r.outboxHeldForDecision.count) outbox messages came back with the backup and are not sent: open Outbox and send each one or keep it as a draft."))
        }
        if !r.unreadable.isEmpty {
            parts.append(String(localized: "\(r.unreadable.count) drafts or outbox items could not be read; they are listed, not sent."))
        }
        return parts.joined(separator: " ")
    }

    static func restorePrepareFailed(_ why: String) -> String {
        String(localized: "Connected mail could not be prepared after the restore (\(why)). Nothing is sent and no account connects until it is.")
    }

    // MARK: Removal

    static func countChangedAfterRemoval(shown: Int, now: Int) -> String {
        String(localized: "The account was removed and its mail kept. It now has \(now) messages to delete, not the \(shown) shown. Type the new number to delete them.")
    }

    static var nothingToDelete: String { String(localized: "No Archived Mail to Delete") }

    static func keptMessages(_ count: Int) -> String {
        String(localized: "Removed; \(count) archived messages kept")
    }

    // MARK: Adding again / signing in again

    static func alreadyAdded(_ address: String) -> String {
        String(localized: "\(address) is already added. Choose it in Accounts and status.")
    }

    static func reconnected(_ address: String) -> String {
        String(localized: "\(address) was added before, so mailin connected that account again: mail it already saved is not downloaded again.")
    }

    static func otherMailbox(signedIn: String, account: String) -> String {
        String(localized: "You signed in as \(signedIn), but this account is \(account). Nothing was changed. Sign in with \(account), or add \(signedIn) as a new account.")
    }

    // MARK: Password

    static var passwordReplaced: String { String(localized: "Password replaced. The account is signed in again.") }

    /// The login check before an IMAP account (or its new password) is saved failed.
    /// Worded for the server `mailHost`: a coded IMAP /
    /// SMTP refusal (IMAP off, web sign-in, app password, too many
    /// connections, certificate, TLS) gets its own sentence; only a real
    /// password refusal is Gmail's app-password advice.
    static func loginRefused(_ error: AccountLoginCheckError, mailHost: String?) -> String {
        if let coded = ConnectedMailErrorText.codedSentence(for: error, mailHost: mailHost) {
            return String(localized: "\(coded) Nothing was saved.")
        }
        let gmail = ConnectedMailErrorText.isGmailHost(mailHost)
        switch error {
        case .incoming(let why):
            if isPasswordRefusal(why) {
                return gmail ? ConnectedMailErrorText.gmailAppPasswordRefused
                             : String(localized: "The incoming mail server refused the user name or password. Nothing was saved.")
            }
            return String(localized: "The incoming mail server did not accept the sign-in (\(why)). Nothing was saved.")
        case .outgoing(let why):
            if isPasswordRefusal(why) {
                return gmail ? ConnectedMailErrorText.gmailAppPasswordRefused
                             : String(localized: "The outgoing mail server refused the user name or password. Nothing was saved.")
            }
            return String(localized: "The outgoing mail server did not accept the sign-in (\(why)). Nothing was saved.")
        }
    }

    /// The login check's words for a refused user name or password
    /// (`IMAPLoginCheck.describe`, `SMTPLoginCheck`).
    static let passwordRefusedReason = "the user name or password was refused"

    static func isPasswordRefusal(_ why: String) -> Bool { why.hasPrefix(passwordRefusedReason) }

    // MARK: Sending identity

    static func loginMustBeAddress(_ provider: String) -> String {
        String(localized: "For \(provider), the login name must be the email address.")
    }

    static func addressNotConfirmed(_ address: String) -> String {
        String(localized: "mailin has not confirmed that this server lets you send as \(address). Confirm it only if this is your own address on this server.")
    }

    static var addressConfirmed: String { String(localized: "Sending address confirmed.") }

    // MARK: Limits

    /// Microsoft Graph takes one message of at most 4 MB once encoded.
    static func graphTooLarge(encodedBytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(encodedBytes), countStyle: .file)
        return String(localized: "This message is \(size) once encoded for sending; Microsoft accepts at most 4 MB per message. Remove or shrink attachments, then send it again. Nothing was queued.")
    }

    // MARK: Search index

    static func searchRemovalFailed(failed: Int, total: Int) -> String {
        String(localized: "\(failed) of \(total) messages could not be removed from search, so nothing was deleted. Try again; if it keeps failing, rebuild the search index.")
    }

    // MARK: Sync now

    static var allCapturePaused: String {
        String(localized: "Every account that saves mail is paused. Resume one in Accounts and status to sync.")
    }
}
