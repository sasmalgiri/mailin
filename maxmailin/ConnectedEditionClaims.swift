import MailConnectivity
//
//  ConnectedEditionClaims.swift
//  maxmailin
//
//  Plan v4 V4-14 (§3 A17, §10, §13.8, T47): what the app says about the
//  network must be true of THIS binary.
//
//   • The offline edition (no mail transport compiled) keeps every word it
//     shipped with: "No account, no mail servers …" is true there.
//   • The connected edition (`MAILIN_CONNECTED_MAIL`) may not say that: it
//     can talk to the person's own mail providers once Connected mail is on
//     and an account is added. Its text says so, and says what stays true
//     (no mailin server, no relay, no data collection, no cloud AI).
//   • T47: a connected Release build must carry real OAuth client IDs, not
//     placeholders. `ConnectedReleaseCheck` states every problem; it is run
//     on the candidate by `V414ClaimsTests` and `Scripts/check-connected-release.sh`.
//

import Foundation

// MARK: - About ▸ privacy line

enum EditionPrivacyClaim {
    struct Text: Equatable, Sendable {
        let title: String
        let detail: String
    }

    /// The line for this binary and the current Connected mail switch.
    static func current() -> Text {
        about(mailTransportsCompiled: ConnectedBuildFeatures.mailTransportsCompiled,
              connectedMailOn: MailNetworkPolicy.shared.isMailEnabled)
    }

    static func about(mailTransportsCompiled: Bool, connectedMailOn: Bool) -> Text {
        guard mailTransportsCompiled else {
            // The offline edition: unchanged wording (true for this binary).
            return Text(title: String(localized: "Offline & Private"),
                        detail: String(localized: "No account, no mail servers, no data collection. Your archive never leaves your device."))
        }
        let title = String(localized: "Private by design")
        if connectedMailOn {
            return Text(title: title, detail: String(localized: "Your archive stays on this device. Connected mail is on: this device connects directly to the mail providers of the accounts you added, only for what you allowed each one. Nothing goes through a mailin server, and mailin collects no data."))
        }
        return Text(title: title, detail: String(localized: "Your archive stays on this device. Connected mail is off, so nothing connects to a mail server until you turn it on and add an account. There is no mailin server, and mailin collects no data."))
    }
}

// MARK: - About ▸ Privacy Policy summary

extension LegalComplianceManager {
    /// The privacy summary for this binary. The offline edition shows the
    /// summary it shipped with; the connected edition shows one that
    /// describes its mail connections (English, like the other legal texts).
    static func privacyPolicyText(mailTransportsCompiled: Bool = ConnectedBuildFeatures.mailTransportsCompiled) -> String {
        mailTransportsCompiled ? connectedPrivacyPolicySummary : privacyPolicySummary
    }

    static let connectedPrivacyPolicySummary = """
    PRIVACY POLICY SUMMARY (connected edition)

    Data Collection: mailin collects NO personal data. Zero analytics, zero tracking, zero telemetry. There is no mailin server: nothing you import, save, search or send reaches the developer.

    On-Device Processing: Email parsing, search indexing, duplicate detection, exports and the on-device AI features run entirely on your device. This edition contains no cloud AI: no email content is sent to an AI provider.

    Connected Mail (optional, off until you turn it on): when you turn on Connected mail and add an account, this device connects directly to that account's own mail provider — Google (Gmail API), Microsoft (Microsoft Graph) or the IMAP and SMTP servers you enter — only for what you allow that account: save a copy of its mail (read-only), send mail you submit from the outbox, or change mail on the server when you choose to. Nothing is relayed through any other server. The provider handles your mail under its own terms and privacy policy.

    Sign-in: you sign in on the provider's own page. mailin receives sign-in tokens (Gmail, Outlook) or uses the password or app password you enter (IMAP); they are kept only in this device's Keychain, are never synchronised and are never included in backups or exports.

    Data Storage: Saved mail, drafts and the outbox are stored locally in your archive folder. Removing an account deletes its sign-in data from the Keychain and keeps its saved mail; deleting that mail is a separate step that shows the count first. To also withdraw mailin's access at the provider, remove it in your Google or Microsoft account's app permissions.

    Third-Party Services: Apple App Store for purchases. Your own mail providers, only as described above. No advertising SDKs, no analytics frameworks, no tracking.

    Data Deletion: You can delete all data at any time via Settings > Data & Privacy > Delete All Data. This also deletes every connected account's sign-in data from this device's Keychain.

    Children: mailin is not directed at children under 13 and does not knowingly collect data from children.

    Contact: sasmalgiri@gmail.com

    Full policy: https://sasmalgiri.github.io/mailin/privacy
    """
}

// MARK: - T47: connected Release configuration check

enum ConnectedReleaseCheck {
    struct Problem: Equatable, Sendable, CustomStringConvertible {
        let key: String
        let reason: String
        var description: String { "\(key): \(reason)" }
    }

    static let gmailClientIDKey = MailProviderChoice.gmailClientIDKey
    static let graphClientIDKey = MailProviderChoice.graphClientIDKey
    static let graphRedirectKey = MailProviderChoice.graphRedirectKey

    /// Every reason `info` (an app's Info.plist) is not ready for a connected
    /// Release. An offline build has nothing to check (its sign-in code is
    /// not compiled), so it returns no problem.
    static func problems(info: [String: Any], mailTransportsCompiled: Bool) -> [Problem] {
        guard mailTransportsCompiled else { return [] }
        var out: [Problem] = []

        // Gmail: a Google iOS-type client ID (also used by the Mac app).
        if let raw = info[gmailClientIDKey] as? String {
            do { _ = try GmailOAuth.validateClientID(raw) } catch {
                out.append(Problem(key: gmailClientIDKey, reason: error.localizedDescription))
            }
        } else {
            out.append(Problem(key: gmailClientIDKey, reason: "missing"))
        }

        // Microsoft: the Entra Application (client) ID.
        if let raw = info[graphClientIDKey] as? String {
            do { try GraphOAuth.validateClientID(raw) } catch {
                out.append(Problem(key: graphClientIDKey, reason: error.localizedDescription))
            }
        } else {
            out.append(Problem(key: graphClientIDKey, reason: "missing"))
        }

        // Microsoft redirect: `msauth.<this bundle ID>://auth`, as Entra's
        // iOS / macOS platform registers it for this bundle.
        let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
        if let raw = info[graphRedirectKey] as? String {
            if let why = redirectProblem(raw, bundleID: bundleID) {
                out.append(Problem(key: graphRedirectKey, reason: why))
            }
        } else {
            out.append(Problem(key: graphRedirectKey, reason: "missing"))
        }

        // V4-16: how Gmail is offered. "imap" (app password, the 4.0 App
        // Store value) or "oauth" (Google sign-in); missing reads as "imap".
        if let raw = info[gmailSignInModeKey] as? String, gmailSignInModeValue(raw) == nil {
            out.append(Problem(key: gmailSignInModeKey, reason: "expected imap or oauth, found \(raw.isEmpty ? "an empty value" : raw)"))
        }
        return out
    }

    static let gmailSignInModeKey = MailProviderChoice.gmailSignInModeKey

    /// The mode a value names exactly, or nil for anything else.
    static func gmailSignInModeValue(_ raw: String) -> MailProviderChoice.GmailSignInMode? {
        MailProviderChoice.GmailSignInMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func redirectProblem(_ raw: String, bundleID: String) -> String? {
        let lower = raw.lowercased()
        if raw.isEmpty { return "empty" }
        if ["your", "placeholder", "<", "$(", "todo", "example"].contains(where: { lower.contains($0) }) {
            return "placeholder (\(raw))"
        }
        guard let url = URL(string: raw), let scheme = url.scheme else { return "not a URL (\(raw))" }
        guard !bundleID.isEmpty else { return "CFBundleIdentifier is missing, so the redirect cannot be checked" }
        let expected = "msauth.\(bundleID)://auth"
        guard scheme.lowercased() == "msauth.\(bundleID.lowercased())", url.host == "auth", url.path.isEmpty || url.path == "/" else {
            return "expected \(expected) for this bundle, found \(raw)"
        }
        return nil
    }

    /// This binary's own Info.plist.
    static func problemsForThisBuild(_ bundle: Bundle = .main) -> [Problem] {
        problems(info: bundle.infoDictionary ?? [:], mailTransportsCompiled: ConnectedBuildFeatures.mailTransportsCompiled)
    }
}
