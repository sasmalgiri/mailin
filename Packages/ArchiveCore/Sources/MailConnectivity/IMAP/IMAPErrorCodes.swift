//
//  IMAPErrorCodes.swift
//  MailConnectivity
//
//  Stable codes for IMAP / SMTP refusals the app words itself (audit
//  2026-11-14). A coded error is `MailProviderError.permanent("<code>: <detail>")`
//  (`.transient` for `tooManyConnections`), the same "<prefix>: …" form as
//  `GraphAdapter.noMailboxPrefix`; an SMTP outcome's `reason` starts with the
//  code the same way. `<detail>` keeps the server's own words (an [ALERT] text
//  is never dropped). `IMAPErrorCode.code(of:)` / `code(in:)` read the code back.
//

import Foundation

public enum IMAPErrorCode {
    // Sign-in refusals (the server's text after the code, verbatim).
    /// IMAP is switched off for the account (Gmail "not enabled for IMAP use"),
    /// or by a Workspace / domain administrator. Permanent.
    public static let imapDisabled = "imapDisabled"
    /// The provider wants a sign-in in a web browser first ("Please log in via
    /// your web browser", [WEBALERT]). Permanent until the person has done it.
    public static let webLoginRequired = "imapWebLoginRequired"
    /// The provider needs an application-specific password. Permanent.
    public static let appPasswordRequired = "imapAppPasswordRequired"
    /// Too many simultaneous connections to the account. TRANSIENT: retried.
    public static let tooManyConnections = "imapTooManyConnections"
    /// The password (or token) was refused. Not carried in the error — that
    /// stays `.reauthorisationRequired` (OAuth: `.unauthorized`) so the engine
    /// asks for sign-in — but in `IMAPSignInRefusal.code`, with the server's text.
    public static let authenticationFailed = "imapAuthenticationFailed"

    // TLS (permanent: retrying cannot make a certificate trusted).
    /// The server's certificate is not trusted for the host (expired, unknown
    /// root, wrong host name …).
    public static let certificateNotTrusted = "imapCertificateNotTrusted"
    /// The TLS handshake failed for another reason (e.g. the port speaks plaintext).
    public static let tlsHandshakeFailed = "imapTLSHandshakeFailed"
    /// SMTP: as `certificateNotTrusted` (`SubmissionOutcome.retry(reason:…, automatic: false)`).
    public static let smtpCertificateNotTrusted = "smtpCertificateNotTrusted"
    /// SMTP: as `tlsHandshakeFailed`.
    public static let smtpTLSHandshakeFailed = "smtpTLSHandshakeFailed"

    // Stated limits on a listing (`IMAPAdapter.listingLimits`).
    /// Gmail: [Gmail]/All Mail is hidden from IMAP ("Show in IMAP" off), so
    /// archived mail with no label cannot be listed. Enable "Show in IMAP" for
    /// All Mail in Gmail's settings (Labels).
    public static let gmailAllMailHidden = "gmailAllMailHiddenFromIMAP"

    public static let all: [String] = [imapDisabled, webLoginRequired, appPasswordRequired, tooManyConnections,
                                       authenticationFailed, certificateNotTrusted, tlsHandshakeFailed,
                                       smtpCertificateNotTrusted, smtpTLSHandshakeFailed, gmailAllMailHidden]

    static func coded(_ code: String, _ detail: String) -> String { "\(code): \(detail)" }

    /// The code a reason string starts with, if any.
    public static func code(in reason: String) -> String? {
        guard let colon = reason.range(of: ": ") else { return all.first { reason == $0 } }
        let head = String(reason[..<colon.lowerBound])
        return all.contains(head) ? head : nil
    }

    /// The text after the code (the server's words); the whole string when uncoded.
    public static func detail(in reason: String) -> String {
        guard code(in: reason) != nil, let colon = reason.range(of: ": ") else { return reason }
        return String(reason[colon.upperBound...])
    }

    /// The code of a `MailProviderError.permanent / .transient` from IMAP.
    public static func code(of error: Error) -> String? {
        switch error {
        case MailProviderError.permanent(let why), MailProviderError.transient(let why): return code(in: why)
        default: return nil
        }
    }
}

/// Why the server refused a sign-in: the code and the server's own text
/// (an [ALERT] is kept word for word). `IMAPAdapter.lastSignInRefusal`.
public struct IMAPSignInRefusal: Sendable, Equatable {
    public var code: String
    public var serverText: String
    /// The server marked the text [ALERT] / [WEBALERT]: it must be shown (RFC 9051 §7.1).
    public var isAlert: Bool

    public init(code: String, serverText: String, isAlert: Bool) {
        self.code = code; self.serverText = serverText; self.isAlert = isAlert
    }

    /// Classifies a refused AUTHENTICATE / LOGIN (or a BYE greeting).
    static func classify(_ s: IMAPStatusResponse) -> IMAPSignInRefusal {
        let codeName = s.code?.name.uppercased() ?? ""
        let text = s.text.isEmpty ? s.status.rawValue : s.text
        let haystack = (s.text + " " + (s.code?.argument ?? "")).lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { haystack.contains($0) } }
        let code: String
        if has(["too many simultaneous", "too many connections", "too many concurrent", "maximum number of connections",
                "connection limit", "too many open connections"]) {
            code = IMAPErrorCode.tooManyConnections
        } else if has(["application-specific password", "application specific password", "app-specific password",
                       "app password"]) {
            code = IMAPErrorCode.appPasswordRequired
        } else if codeName == "WEBALERT" || has(["web browser", "web login required", "log in via your web",
                                                 "sign in via your web", "webloginrequired"]) {
            code = IMAPErrorCode.webLoginRequired
        } else if has(["not enabled for imap", "imap access is disabled", "imap access disabled", "imap is disabled",
                       "imap access is not enabled", "imap is not enabled", "imap use is disabled", "imap disabled",
                       "enable imap", "imap access for your domain", "domain administrator"]) {
            code = IMAPErrorCode.imapDisabled
        } else {
            code = IMAPErrorCode.authenticationFailed
        }
        return IMAPSignInRefusal(code: code, serverText: text, isAlert: codeName == "ALERT" || codeName == "WEBALERT")
    }

    /// The error the engine sees: a coded `.permanent` / `.transient`, or nil
    /// for a plain refusal (the caller keeps `.reauthorisationRequired`).
    var codedError: MailProviderError? {
        switch code {
        case IMAPErrorCode.tooManyConnections: return .transient(IMAPErrorCode.coded(code, serverText))
        case IMAPErrorCode.imapDisabled, IMAPErrorCode.webLoginRequired, IMAPErrorCode.appPasswordRequired:
            return .permanent(IMAPErrorCode.coded(code, serverText))
        default: return nil
        }
    }
}
