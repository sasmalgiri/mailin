@testable import ArchiveCore
import MailConnectivity
//
//  MailWorkspaceModel.swift
//  maxmailin
//
//  Plan v4 V4-13 (§2 two workspaces Archive and Mail; §5.4 statuses; §6; §7):
//  everything the Mail workspace decides, without SwiftUI and without a
//  network. The views in MailWorkspaceView*.swift only draw what this file
//  says; MailWorkspaceTests drive this file with a fake backend.
//
//  Rules applied here:
//   • The edition decides first: a build without the mail transports shows
//     one honest state and NO actionable control (no Add, no Sync, no
//     Compose) — `MailWorkspaceModel.actions` is empty there.
//   • A provider whose sign-in is not configured (missing or placeholder
//     client ID) is listed with the reason, and its Add button does nothing.
//   • A new account is allowed nothing: Preserve mail, Send mail and Change
//     server mail are all off until the person switches each on.
//   • Removing an account shows its counts first (rule 4), keeps its
//     archived mail, and deleting that mail is a separate step that names
//     the exact count.
//   • A draft cannot be queued without an explicitly chosen sending identity
//     of the draft's own account.
//   • A server cleanup runs only after the person types the exact count the
//     preview showed.
//

import Foundation
import Observation

// MARK: - Edition and availability

enum MailWorkspaceAvailability: Equatable, Sendable {
    /// The binary has no mail connection code (the offline edition).
    case notInThisEdition
    /// The code is here but Mail (the connected-mail switch) is off, or the runtime is not running.
    case mailSwitchedOff
    case ready

    var title: String {
        switch self {
        case .notInThisEdition: return String(localized: "This edition has no mail connection")
        case .mailSwitchedOff: return String(localized: "Mail is switched off")
        case .ready: return String(localized: "Mail")
        }
    }

    var detail: String {
        switch self {
        case .notInThisEdition:
            return String(localized: "This copy of mailin was built without any code that connects to a mail server, so no account can be added here. Everything in Archive works as before: open archives, keep folders, search messages and attachments, find duplicates and verify exports.")
        case .mailSwitchedOff:
            return String(localized: "Connected mail is off, so nothing connects to a mail server. Turn on “Connected mail” to add accounts. Mail already saved in the archive stays readable, searchable and exportable.")
        case .ready: return ""
        }
    }
}

/// What the person can do on the page right now. Empty unless the edition
/// and the switch allow mail (the offline build shows no actionable control).
enum MailWorkspaceAction: String, CaseIterable, Sendable {
    case addAccount, syncNow, compose, openOutbox, cleanup
}

// MARK: - Providers and client IDs

enum MailProviderChoice: String, CaseIterable, Identifiable, Sendable {
    /// Gmail with Google sign-in (OAuth, Gmail API). Offered only when the
    /// build's `MailinGmailSignInMode` is "oauth" (TestFlight / demo builds;
    /// 4.0.x once Google has verified the restricted scopes).
    case gmail
    case outlook, iCloud, fastmail, otherIMAP
    /// V4-16: Gmail over IMAP with a Google app password — the 4.0 App Store
    /// Gmail path (`MailinGmailSignInMode` "imap" or missing).
    case gmailAppPassword
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail, .gmailAppPassword: return String(localized: "Gmail")
        case .outlook: return String(localized: "Outlook and Microsoft 365")
        case .iCloud: return String(localized: "iCloud Mail")
        case .fastmail: return String(localized: "Fastmail")
        case .otherIMAP: return String(localized: "Other IMAP server")
        }
    }

    var provider: MailProviderKind {
        switch self {
        case .gmail: return .gmail
        case .outlook: return .microsoftGraph
        case .iCloud, .fastmail, .otherIMAP, .gmailAppPassword: return .imap
        }
    }

    var usesOAuth: Bool { provider != .imap }

    var preset: IMAPProviderPreset? {
        switch self {
        case .iCloud: return .iCloud
        case .fastmail: return .fastmail
        case .otherIMAP: return .generic(host: "")
        case .gmailAppPassword: return .gmail
        case .gmail, .outlook: return nil
        }
    }

    /// What the person must do at the provider (the preset's note, localised).
    var signInNote: String? {
        switch self {
        case .iCloud: return String(localized: "Use an app-specific password from your Apple Account settings. Keep two-factor authentication on.")
        case .fastmail: return String(localized: "Use an app password created in Fastmail's Privacy & Security settings.")
        case .otherIMAP: return String(localized: "Use the server settings your mail provider publishes.")
        case .gmailAppPassword: return Self.gmailAppPasswordGuidance
        case .gmail, .outlook: return nil
        }
    }

    /// V4-16: what Gmail over IMAP needs, shown beside the password field.
    static var gmailAppPasswordGuidance: String {
        String(localized: "Google requires 2-Step Verification for this. Create an app password at myaccount.google.com/apppasswords and paste the 16-character password here. A normal Google password will be refused.")
    }

    /// The password field's label.
    var passwordLabel: String {
        self == .gmailAppPassword ? String(localized: "App password") : String(localized: "Password or app password")
    }

    /// The outgoing server the preset implies (nil = the person enters one).
    var smtpDefault: MailAccountExtras.SMTP? {
        switch self {
        case .iCloud: return .init(host: "smtp.mail.me.com", port: 587, implicitTLS: false)
        case .fastmail: return .init(host: "smtp.fastmail.com", port: 465, implicitTLS: true)
        case .gmailAppPassword: return .init(host: "smtp.gmail.com", port: 465, implicitTLS: true)
        case .otherIMAP, .gmail, .outlook: return nil
        }
    }

    /// Info.plist keys holding the owner's registered client IDs (V4-14).
    static let gmailClientIDKey = "MailinGmailClientID"
    static let graphClientIDKey = "MailinGraphClientID"
    static let graphRedirectKey = "MailinGraphRedirectURI"
    /// V4-16: how Gmail is offered in Add account — "imap" (app password, the
    /// 4.0 App Store value in Info-Connected.plist) or "oauth" (Google sign-in;
    /// TestFlight / demo builds set it). Missing or anything else = "imap".
    static let gmailSignInModeKey = "MailinGmailSignInMode"

    enum GmailSignInMode: String, Sendable { case imap, oauth }

    static func gmailSignInMode(info: [String: String]) -> GmailSignInMode {
        let raw = (info[gmailSignInModeKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == GmailSignInMode.oauth.rawValue ? .oauth : .imap
    }

    /// The providers Add account lists, in order: ONE Gmail choice — Google
    /// sign-in when the mode is "oauth", the app-password path otherwise.
    /// The other Gmail path stays in the code, switched off (rule 14).
    static func offered(info: [String: String]) -> [MailProviderChoice] {
        let gmail: MailProviderChoice = gmailSignInMode(info: info) == .oauth ? .gmail : .gmailAppPassword
        return [gmail, .outlook, .iCloud, .fastmail, .otherIMAP]
    }

    enum Readiness: Equatable, Sendable {
        case ready
        /// The Add button is shown disabled, with this reason. It does nothing.
        case unavailable(String)
        var isReady: Bool { self == .ready }
    }

    /// Whether this provider can be added with the given Info.plist values.
    /// A missing or placeholder client ID is never used for a request.
    func readiness(info: [String: String]) -> Readiness {
        switch self {
        case .gmail:
            do { _ = try GmailOAuth.configuration(clientID: info[Self.gmailClientIDKey] ?? "") } catch {
                return .unavailable(Self.notConfiguredReason(self))
            }
            return .ready
        case .outlook:
            guard let redirect = URL(string: info[Self.graphRedirectKey] ?? ""), redirect.scheme != nil else {
                return .unavailable(Self.notConfiguredReason(self))
            }
            do {
                _ = try GraphOAuth.configuration(GraphSignInSettings(clientID: info[Self.graphClientIDKey] ?? "", redirectURI: redirect))
            } catch { return .unavailable(Self.notConfiguredReason(self)) }
            return .ready
        case .iCloud, .fastmail, .otherIMAP, .gmailAppPassword:
            return .ready
        }
    }

    static func notConfiguredReason(_ choice: MailProviderChoice) -> String {
        switch choice {
        case .gmail:
            return String(localized: "Gmail sign-in is not set up in this build: it has no registered Google client ID. Add the account as IMAP instead, or use a build that has one.")
        case .outlook:
            return String(localized: "Microsoft sign-in is not set up in this build: it has no registered Microsoft app ID and redirect address.")
        default: return ""
        }
    }

    /// The app's Info.plist values for the client-ID keys.
    static func bundleInfo(_ bundle: Bundle = .main) -> [String: String] {
        var out: [String: String] = [:]
        for key in [gmailClientIDKey, graphClientIDKey, graphRedirectKey, gmailSignInModeKey] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String { out[key] = value }
        }
        return out
    }
}

// MARK: - Modes

enum MailModeText {
    /// Why `mode` cannot be switched on for this account in this version (nil = it can).
    /// Gmail over IMAP with an app password (4.0): changing server mail is not supported —
    /// a Gmail message sits in several label folders, so a folder-level change is unsafe.
    static func unavailableReason(_ mode: MailAccount.Mode, account: MailAccount) -> String? {
        guard mode == .serverActions, account.provider == .imap, ConnectedMailErrorText.isGmailHost(account.host) else { return nil }
        return String(localized: "Not available for Gmail with an app password in this version. Saving and sending mail work.")
    }

    static func title(_ mode: MailAccount.Mode) -> String {
        switch mode {
        case .capture: return String(localized: "Preserve mail")
        case .send: return String(localized: "Send mail")
        case .serverActions: return String(localized: "Change server mail")
        }
    }

    /// What switching the mode on allows — shown beside every toggle.
    static func explanation(_ mode: MailAccount.Mode) -> String {
        switch mode {
        case .capture:
            return String(localized: "Reads mail from the server and keeps a copy in the archive. Read-only: nothing on the server is changed, and nothing is marked as read.")
        case .send:
            return String(localized: "Lets you send mail from this account's own address. Each message waits in the outbox first and is sent only when you send it.")
        case .serverActions:
            return String(localized: "Lets you change mail on the server when you choose to: mark read or unread, flag, move, and move to Trash. Every change is listed, and nothing happens on its own.")
        }
    }

    static let order: [MailAccount.Mode] = [.capture, .send, .serverActions]
}

// MARK: - Status wording (§5.4)

enum MailStatusText {
    /// The localised headline for a capture status.
    static func headline(_ status: CaptureStatus) -> String {
        switch status.headline {
        case .needsSignIn: return String(localized: "Account needs sign-in; saved mail remains available")
        case .paused(.driveUnavailable):
            if let drive = status.missingDrive {
                return String(localized: "Capture paused: reconnect the drive “\(drive.volumeName)” that holds the archive")
            }
            return String(localized: "Capture paused: drive unavailable")
        case .paused(.diskFull): return String(localized: "Capture paused: not enough free space")
        case .paused(.quotaExceeded): return String(localized: "Capture paused: the provider's limit was reached; it resumes later")
        case .paused(.rateLimited): return String(localized: "Capture paused: the provider asked mailin to slow down; it resumes later")
        case .notPermitted: return String(localized: "Capture is not allowed for this account")
        case .capturing(let saved, let remaining?): return String(localized: "Saving mail: \(saved) saved, \(remaining) to go")
        case .capturing(let saved, nil): return String(localized: "Saving mail: \(saved) saved so far")
        case .inventoryUnknown(let saved): return String(localized: "\(saved) saved; the mailbox has not been fully listed yet")
        case .savedWithFailures(_, let failed): return String(localized: "Saved locally; \(failed) could not be downloaded yet")
        case .savedTextPending: return String(localized: "Saved locally; attachment text pending")
        case .upToDate(let saved, _): return String(localized: "Up to date: \(saved) saved from the selected folders")
        case .lastRunStopped(let why): return String(localized: "Last capture stopped (\(why)); saved mail remains available")
        }
    }

    /// The four kinds of completeness, one line each (§5.4).
    static func completenessLines(_ s: CaptureStatus) -> [(title: String, value: String)] {
        let a = s.completeness.acquisition
        let p = s.completeness.preservation
        var lines: [(String, String)] = []
        let acquisition = a.inventoryKnown
            ? String(localized: "\(a.captured) captured, \(a.remaining) remaining, \(a.failed) failed, \(a.unavailable) unavailable")
            : String(localized: "\(a.captured) captured; the server's list is not complete yet")
        lines.append((String(localized: "Acquisition"), acquisition))
        let bytes = ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)
        lines.append((String(localized: "Preservation"),
                      String(localized: "\(p.recordsWithBytes) kept with their original bytes (\(bytes)); \(p.recordsMissingBytes) missing bytes; \(p.unreadable) unreadable")))
        if let search = s.search {
            lines.append((String(localized: "Search coverage"),
                          String(localized: "Bodies: \(search.bodiesIndexed) indexed, \(search.bodiesPending) pending. Attachments: \(search.attachmentsIndexed) indexed, \(search.attachmentsPending) pending, \(search.attachmentsUnavailable) locked, unsupported or failed")))
        } else {
            lines.append((String(localized: "Search coverage"), String(localized: "Not measured yet")))
        }
        if let export = s.export {
            lines.append((String(localized: "Export verification"),
                          String(localized: "\(export.exportsVerified) exports verified, \(export.exportsWithMismatches) with differences")))
        } else {
            lines.append((String(localized: "Export verification"), String(localized: "No export of this account's mail has been verified yet")))
        }
        return lines
    }

    static func syncTimes(_ s: CaptureStatus) -> (successful: String, attempted: String) {
        func text(_ d: Date?) -> String {
            d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Never")
        }
        return (text(s.lastSuccessfulSync), text(s.lastAttemptedSync))
    }
}

// MARK: - Outbox wording

enum MailOutboxText {
    /// The one line shown for an outbox item. Acceptance is never called delivery.
    static func state(_ state: OutboxState) -> String {
        switch state {
        case .draft: return String(localized: "Draft")
        case .queued: return String(localized: "Waiting to send")
        case .submitting: return String(localized: "Sending…")
        case .accepted: return String(localized: "Accepted by the mail provider, not yet confirmed delivered")
        case .sentReconciled(_, .foundInSent): return String(localized: "Sent: found in the account's Sent folder")
        case .sentReconciled(_, .appendedToSent): return String(localized: "Sent: a copy was saved to the Sent folder")
        case .sentReconciled(_, .providerResponse): return String(localized: "Sent: the provider confirmed it")
        case .cancelledBeforeSubmission: return String(localized: "Not sent: cancelled before it left this device")
        case .rejected(let reason, _): return String(localized: "Not sent: the provider refused it (\(reason))")
        case .retryWaiting(let reason, let notBefore, _, _):
            return String(localized: "Not sent yet: \(reason). Trying again after \(notBefore.formatted(date: .omitted, time: .shortened))")
        case .needsSignIn: return String(localized: "Not sent: the account needs sign-in")
        case .outcomeUncertain(_, .notChecked): return String(localized: "Send outcome uncertain; checking Sent")
        case .outcomeUncertain(_, .notFound): return String(localized: "Send outcome uncertain: not found in Sent. You can send it again.")
        case .outcomeUncertain(_, .lookupFailed): return String(localized: "Send outcome uncertain: Sent could not be checked. You can send it again.")
        }
    }

    /// "Resend anyway" exists only after an uncertain outcome was checked.
    static func canResendAnyway(_ state: OutboxState) -> Bool {
        if case .outcomeUncertain(_, let reconciliation) = state { return reconciliation != .notChecked }
        return false
    }

    static func canCheckSent(_ state: OutboxState) -> Bool {
        switch state {
        case .outcomeUncertain, .accepted: return true
        default: return false
        }
    }

    static func canCancel(_ state: OutboxState) -> Bool {
        switch state {
        case .draft, .queued, .retryWaiting, .needsSignIn: return true
        default: return false
        }
    }

    static func canRetryNow(_ state: OutboxState) -> Bool {
        switch state {
        case .retryWaiting, .needsSignIn: return true
        default: return false
        }
    }

    /// Seconds left of the undo-send delay, or nil once it has passed (or none was set).
    static func undoSecondsLeft(_ op: OutboxOperation, now: Date) -> Int? {
        guard case .queued = op.state, let notBefore = op.notBefore, notBefore > now else { return nil }
        return Int(notBefore.timeIntervalSince(now).rounded(.up))
    }

    static func hold(_ reason: OutboxHoldReason) -> String {
        switch reason {
        case .sendingPaused: return String(localized: "Not sent yet: sending is paused. Saved mail, drafts and the outbox stay as they are.")
        case .decisionNeededAfterLapse(_, let lapsed):
            let days = max(1, Int((lapsed / 86_400).rounded()))
            return String(localized: "Waiting for you: this message was queued before sending was paused for \(days) days. Send it now, or keep it as a draft.")
        case .restoredFromBackup:
            return String(localized: "Waiting for you: this message came back with a restored backup and may already have been sent. Check Sent, then send it or keep it as a draft.")
        case .accountRemoved: return String(localized: "Not sent: its account was removed. The message is kept.")
        case .archiveDriveMissing(let name): return String(localized: "Not sent yet: the drive “\(name)” that holds the archive is not connected.")
        }
    }
}

// MARK: - Removal

enum MailRemovalText {
    /// The counts shown before an account is removed (rule 4).
    static func summary(_ plan: AccountRemovalPlan) -> [String] {
        [
            String(localized: "\(plan.archive.records) archived messages are kept. They stay readable, searchable and exportable."),
            String(localized: "\(plan.drafts) drafts are kept."),
            String(localized: "\(plan.outboxToKeep) unsent outbox messages are cancelled and kept; none is sent."),
            String(localized: "\(plan.outboxAwaitingOutcome) messages already handed to the provider stay listed until their outcome is known."),
            String(localized: "The account's sign-in details are removed from the Keychain on this device."),
        ]
    }

    static func confirmTitle(_ plan: AccountRemovalPlan) -> String {
        String(localized: "Remove \(plan.account.displayIdentity) and keep its \(plan.archive.records) archived messages")
    }

    static func report(_ r: AccountRemovalReport) -> String {
        String(localized: "Account removed. \(r.archivedRecordsKept) archived messages kept; \(r.keptAsDrafts.count + r.keptInOutbox.count) unsent messages kept; \(r.awaitingOutcome.count) awaiting their outcome.")
    }

    /// The separate, counted deletion of the account's archived mail.
    static func deletionTitle(_ s: ConnectedAccountArchiveSummary) -> String {
        String(localized: "Delete \(s.deletable) archived messages of this account")
    }

    static func deletionDetail(_ s: ConnectedAccountArchiveSummary) -> String {
        String(localized: "\(s.deletable) of \(s.records) messages can be deleted; \(s.held) are on hold and stay. Files other accounts or imports also use stay. This cannot be undone.")
    }
}

// MARK: - Cleanup confirmation

enum MailCleanupGate {
    /// The run button is enabled only when the typed text is exactly the
    /// number of messages the preview will change (and that is not zero).
    static func confirms(typed: String, plan: CleanupPlan) -> Bool {
        let count = plan.included.count
        guard count > 0 else { return false }
        return typed.trimmingCharacters(in: .whitespaces) == String(count)
    }

    static func confirmationPrompt(_ plan: CleanupPlan) -> String {
        String(localized: "Type \(plan.included.count) to change exactly \(plan.included.count) messages on the server of \(plan.preview.accountDisplay).")
    }

    static func actionTitle(_ action: CleanupAction) -> String {
        switch action {
        case .moveToTrash: return String(localized: "Move to the server's Trash")
        case .archiveOnServer: return String(localized: "Archive on the server (remove from Inbox)")
        }
    }

    static func exclusionTitle(_ key: String) -> String {
        switch key {
        case "notCaptured": return String(localized: "Not saved in the archive yet")
        case "captureFailed": return String(localized: "Saving it failed")
        case "archiveRecordMismatch": return String(localized: "The archive copy belongs to another account or message")
        case "archiveBytesMissing": return String(localized: "The archive copy's bytes are missing")
        case "archiveBytesDamaged": return String(localized: "The archive copy no longer matches its saved fingerprint")
        case "archiveUnreadable": return String(localized: "The archive copy could not be checked")
        case "onHold": return String(localized: "On hold")
        case "noIndependentCopy": return String(localized: "No verified export or backup holds it")
        case "duplicateInSelection": return String(localized: "Selected twice")
        case "otherAccount": return String(localized: "Belongs to another account")
        default: return String(localized: "Not supported for this account")
        }
    }

    static func receipt(_ r: CleanupReceipt) -> String {
        String(localized: "\(r.applied) of \(r.selected) changed on the server; \(r.conflicts) changed elsewhere first, \(r.uncertain) uncertain, \(r.rejected) refused, \(r.excluded) not attempted.")
            + " " + (r.archiveCopiesIntact
                     ? String(localized: "Copies saved in mailin: all intact.")
                     : String(localized: "Copies saved in mailin: check the archive health report."))
    }
}

// MARK: - Server change wording

enum MailServerChangeText {
    static func rejection(_ r: RemoteRejection) -> String {
        switch r {
        case .changeServerMailOff: return String(localized: "Changing mail on the server is switched off for this account.")
        case .needsExtraPermission: return String(localized: "This needs extra permission: sign in again and allow mailin to change mail.")
        case .networkNotPermitted: return String(localized: "The server was not contacted: the network policy refused it.")
        case .needsSignIn: return String(localized: "This account needs you to sign in again.")
        case .unsupported, .targetedRemovalUnavailable: return String(localized: "This server cannot make this change safely, so nothing was changed.")
        case .providerRefused: return String(localized: "The server refused the change.")
        case .stateUnavailable: return String(localized: "The message's current state could not be read; nothing was changed.")
        case .accountMismatch: return String(localized: "The message belongs to a different account.")
        }
    }

    static func outcome(_ o: RemoteOperationOutcome?) -> String {
        switch o {
        case .applied(_, true)?: return String(localized: "It was already like that on the server; nothing was sent.")
        case .applied?: return String(localized: "Changed on the server.")
        case .conflict?: return String(localized: "Another app changed this message first; nothing was changed.")
        case .uncertain?: return String(localized: "The change may or may not have reached the server. It is not repeated automatically.")
        case .rejected(let r)?: return rejection(r)
        case nil: return String(localized: "Not attempted.")
        }
    }

    /// The scope a re-consent must request, when the refusal was a missing scope.
    static func missingScope(_ o: RemoteOperationOutcome?) -> String? {
        if case .rejected(.needsExtraPermission(let scope))? = o { return scope }
        return nil
    }
}

// MARK: - Scopes a mode needs

enum MailScopeNeeds {
    static let gmailSend = "https://www.googleapis.com/auth/gmail.send"
    static let graphSend = "Mail.Send"

    /// The OAuth scope the account must still grant before `mode` can work
    /// (nil = granted, or the account signs in without scopes).
    static func missing(_ mode: MailAccount.Mode, account: MailAccount) -> String? {
        let granted = account.grantedScopes.map { $0.lowercased() }
        switch (account.provider, mode) {
        case (.imap, _), (_, .capture): return nil
        case (.gmail, .send):
            return granted.contains(gmailSend) || granted.contains(ServerActionScopes.gmailFullAccess) ? nil : gmailSend
        case (.gmail, .serverActions):
            return ServerActionScopes.missing(for: .gmail(messageID: "scope-check"), granted: account.grantedScopes)
        case (.microsoftGraph, .send):
            return granted.contains { $0 == graphSend.lowercased() || $0.hasSuffix("/" + graphSend.lowercased()) } ? nil : graphSend
        case (.microsoftGraph, .serverActions):
            return ServerActionScopes.missing(for: .graph(mailbox: "me", immutableID: "scope-check"), granted: account.grantedScopes)
        }
    }
}

struct MailReconsentRequest: Equatable, Identifiable {
    var accountID: UUID
    var scope: String
    var mode: MailAccount.Mode?
    var id: String { accountID.uuidString + scope }

    /// Says which mode needs which permission, and what "Not now" does.
    var text: String {
        switch mode {
        case .send?:
            return String(localized: "Send mail needs one more permission: to send email on your behalf. Sign in again and allow it. If you choose Not now, Send mail is switched off again.")
        case .serverActions?:
            return String(localized: "Change server mail needs one more permission: to read, label and move your email. Sign in again and allow it. If you choose Not now, Change server mail is switched off again.")
        case .capture?, nil:
            return String(localized: "This account's sign-in does not yet allow this. Sign in again and allow mailin the extra permission; nothing changes until you do.")
        }
    }

    /// True when the account's granted scopes contain the requested one
    /// (Graph answers with resource-qualified names, e.g. …/Mail.Send).
    static func granted(_ scope: String, in scopes: [String]) -> Bool {
        let wanted = scope.lowercased()
        return scopes.contains { granted in
            let g = granted.lowercased()
            return g == wanted || g.hasSuffix("/" + wanted) || wanted.hasSuffix("/" + g)
        }
    }
}

// MARK: - Compose gate

enum MailComposeGate {
    enum Problem: Equatable {
        case noIdentity
        case identityNotOfAccount
        case noRecipients
        case sendingOff
        case attachmentUnavailable(String)
        /// The account has identities, but the provider never confirmed any
        /// of them: mailin does not send from a typed-only address.
        case addressUnconfirmed
    }

    /// Why the draft cannot be queued yet (empty = it can).
    static func problems(draft: Draft, account: MailAccount?, identities: [SendingIdentity],
                         unavailableAttachments: [String]) -> [Problem] {
        var out: [Problem] = []
        if account?.enabledModes.contains(.send) != true { out.append(.sendingOff) }
        let own = identities.filter { $0.accountID == draft.accountID }
        if !own.isEmpty, !own.contains(where: { $0.permission == .verified }) {
            out.append(.addressUnconfirmed)
        } else if let chosen = draft.senderIdentityID {
            if !identities.contains(where: { $0.id == chosen && $0.accountID == draft.accountID && $0.permission == .verified }) {
                out.append(.identityNotOfAccount)
            }
        } else {
            out.append(.noIdentity)
        }
        if draft.envelopeRecipients.isEmpty { out.append(.noRecipients) }
        out += unavailableAttachments.map { .attachmentUnavailable($0) }
        return out
    }

    static func text(_ p: Problem) -> String {
        switch p {
        case .noIdentity: return String(localized: "Choose which of your connected addresses this message is sent from.")
        case .identityNotOfAccount: return String(localized: "The chosen sending address does not belong to this account.")
        case .noRecipients: return String(localized: "Add at least one recipient.")
        case .sendingOff: return String(localized: "Sending is not turned on for this account. Turn on Send mail in the account's settings.")
        case .attachmentUnavailable(let name): return String(localized: "The attachment “\(name)” is not available. Remove it or attach it again.")
        case .addressUnconfirmed:
            return String(localized: "The provider has not confirmed this account's email address, so mailin does not send from it.")
        }
    }

    /// Only the account's own identities are offered — never an address taken
    /// from an archived message or an archive's former owner.
    static func offeredIdentities(for accountID: UUID, from all: [SendingIdentity]) -> [SendingIdentity] {
        all.filter { $0.accountID == accountID && $0.permission == .verified }
    }
}

// MARK: - Per-account settings that are not secrets

/// What the app keeps per account besides the account record: the stable
/// sending identities and the outgoing server. Never a secret.
struct MailAccountExtras: Codable, Equatable, Sendable {
    struct SMTP: Codable, Equatable, Sendable {
        var host: String
        var port: Int
        var implicitTLS: Bool
    }
    var identities: [SendingIdentity] = []
    var smtp: SMTP?
}

/// UserDefaults-backed (injectable). Holds identities and server names only.
struct MailAccountExtrasStore: @unchecked Sendable {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ id: UUID) -> String { "mailin.connected.extras.\(id.uuidString)" }

    func extras(_ id: UUID) -> MailAccountExtras {
        guard let data = defaults.data(forKey: key(id)),
              let value = try? JSONDecoder().decode(MailAccountExtras.self, from: data) else { return MailAccountExtras() }
        return value
    }

    func save(_ extras: MailAccountExtras, for id: UUID) {
        if let data = try? JSONEncoder().encode(extras) { defaults.set(data, forKey: key(id)) }
    }

    func remove(_ id: UUID) { defaults.removeObject(forKey: key(id)) }

    /// The account's identities; the primary one is created once with a stable id.
    /// `addressConfirmed` false (an OAuth address the provider did not state)
    /// keeps the primary identity `.unverified`: mailin does not send from it.
    func identities(for account: MailAccount, addressConfirmed: Bool = true) -> [SendingIdentity] {
        var e = extras(account.id)
        if e.identities.isEmpty, var primary = try? SendingIdentity.primary(for: account) {
            if !addressConfirmed { primary.permission = .unverified }
            e.identities = [primary]
            save(e, for: account.id)
        }
        return e.identities
    }

    /// After the provider stated the account's address (a later sign-in): the
    /// primary identity becomes that address, verified, keeping its id.
    func confirmPrimaryIdentity(of account: MailAccount) {
        guard let address = try? MailAddress(parsing: account.displayIdentity) else { return }
        var e = extras(account.id)
        if e.identities.isEmpty {
            e.identities = [SendingIdentity(accountID: account.id, address: address, permission: .verified)]
        } else {
            e.identities[0].address = address
            e.identities[0].permission = .verified
        }
        save(e, for: account.id)
    }
}

// MARK: - Onboarding

struct MailIMAPForm: Equatable, Sendable {
    var choice: MailProviderChoice = .iCloud
    var address = ""
    var host = ""
    var port = "993"
    var loginName = ""
    var password = ""
    var smtpHost = ""
    var smtpPort = "587"

    mutating func apply(_ choice: MailProviderChoice) {
        self.choice = choice
        if let preset = choice.preset, choice != .otherIMAP {
            host = preset.host; port = String(preset.port)
        }
        if let smtp = choice.smtpDefault { smtpHost = smtp.host; smtpPort = String(smtp.port) }
    }

    /// Why Add is not possible yet (nil = it is).
    var problem: String? {
        if (try? MailAddress(parsing: address.trimmingCharacters(in: .whitespaces))) == nil {
            return String(localized: "Enter your email address.")
        }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the incoming (IMAP) server.") }
        guard let p = Int(port), (1...65535).contains(p) else { return String(localized: "Enter a port between 1 and 65535.") }
        if password.isEmpty { return String(localized: "Enter the password or app password.") }
        if choice == .gmailAppPassword, secret.count != 16 {
            return String(localized: "A Google app password has 16 characters. Create one at myaccount.google.com/apppasswords; a normal Google password will be refused.")
        }
        return nil
    }

    /// The password as stored: a Google app password is shown in groups of
    /// four ("abcd efgh ijkl mnop"); the spaces are not part of it.
    var secret: String {
        choice == .gmailAppPassword ? password.filter { !$0.isWhitespace } : password
    }
}

enum MailOnboarding {
    /// A new account record: everything off until the person allows it.
    static func newAccount(_ form: MailIMAPForm) -> MailAccount {
        let address = form.address.trimmingCharacters(in: .whitespaces)
        let login = form.loginName.trimmingCharacters(in: .whitespaces)
        return MailAccount(provider: .imap, host: form.host.trimmingCharacters(in: .whitespaces).lowercased(),
                           port: Int(form.port) ?? 993, loginName: login.isEmpty ? address : login,
                           displayIdentity: address, enabledModes: [])
    }

    static func newOAuthAccount(id: UUID, provider: MailProviderKind, issuer: String, tenant: String?, address: String,
                                scopes: [String]) -> MailAccount {
        MailAccount(id: id, provider: provider, issuer: issuer, tenant: tenant,
                    displayIdentity: address.trimmingCharacters(in: .whitespaces), grantedScopes: scopes, enabledModes: [])
    }
}

// MARK: - Backend

/// One account as the workspace shows it.
struct MailAccountSnapshot: Identifiable, Equatable {
    var account: MailAccount
    var status: CaptureStatus?
    /// Why the account has no capture engine (switched off, paused, needs sign-in…).
    var unavailableReason: String?
    var isPaused: Bool
    var lastRunSummary: String?
    /// A capture of the account is under way right now.
    var isRunning = false
    /// When a paused capture (provider throttling or quota) is tried again by itself.
    var nextRetry: Date? = nil
    var id: UUID { account.id }

    /// "Tries again by itself at 14:05", while an automatic retry is scheduled.
    var retryText: String? {
        guard let nextRetry, !isRunning else { return nil }
        let when = nextRetry.formatted(date: .omitted, time: .shortened)
        return String(localized: "mailin tries again by itself at \(when).")
    }

    var headline: String {
        if account.connectionState == .needsReauthorisation { return String(localized: "Account needs sign-in; saved mail remains available") }
        if account.connectionState == .removed { return String(localized: "Removed; its saved mail stays in the archive") }
        if let status {
            let line = MailStatusText.headline(status)
            return retryText.map { line + " " + $0 } ?? line
        }
        return unavailableReason ?? String(localized: "Not saving mail")
    }
}

/// Everything the workspace asks of connected mail. The production
/// implementation is `ConnectedMailBackend`; tests use a fake. Defaults
/// refuse, so a fake implements only what it needs.
@MainActor
protocol MailWorkspaceBackend: AnyObject {
    var availability: MailWorkspaceAvailability { get }
    var providerInfo: [String: String] { get }

    func accounts() async throws -> [MailAccountSnapshot]
    func addIMAP(_ form: MailIMAPForm) async throws -> UUID
    /// Interactive sign-in (OAuth); `existing` re-signs an account (re-consent with `extraScopes`).
    func signIn(_ choice: MailProviderChoice, address: String, existing: UUID?, extraScopes: [String]) async throws -> UUID
    func setMode(_ mode: MailAccount.Mode, enabled: Bool, account: UUID) async throws
    func syncNow(_ account: UUID) async
    func setPaused(_ paused: Bool, account: UUID) async throws
    func folders(_ account: UUID) async throws -> [ConnectedFolderSummary]
    func setFolderSelected(_ serverID: String, selected: Bool, account: UUID) async throws

    func removalPlan(_ account: UUID) async throws -> AccountRemovalPlan
    func remove(_ account: UUID) async throws -> AccountRemovalReport
    func archiveDeletionPlan(_ account: UUID) async throws -> ConnectedAccountArchiveSummary
    func deleteArchivedMail(_ account: UUID, confirmedCount: Int) async throws -> ConnectedAccountArchiveDeletion

    func mailbox(_ query: ConnectedMailboxQuery, after: ConnectedMailboxCursor?) async throws -> ConnectedMailboxPage
    func email(_ id: UUID) async throws -> MBOXParser.RawEmail?
    func changeOnServer(_ request: RemoteChangeRequest, row: ConnectedMailboxRow) async throws -> RemoteOperation

    func identities(_ account: UUID) async -> [SendingIdentity]
    func drafts() async -> DraftListing
    func createDraft(_ seed: DraftSeed) async throws -> Draft
    func saveDraft(_ draft: Draft) async throws -> Draft
    func discardDraft(_ id: UUID) async throws
    func attachmentAvailability(_ attachment: DraftAttachment, draft: UUID) async -> DraftAttachmentAvailability
    func addAttachment(_ file: URL, to draft: Draft) async throws -> Draft
    func archivedSource(_ emailID: UUID) async throws -> ArchivedMessageSource
    func queue(_ draft: Draft, undoDelay: TimeInterval) async throws -> OutboxOperation

    func outbox() async throws -> [OutboxOperation]
    func outboxHolds() async -> [UUID: OutboxHoldReason]
    func cancelSend(_ id: UUID) async throws
    func checkSent(_ id: UUID) async throws
    func resendAnyway(_ id: UUID) async throws
    func retryNow(_ id: UUID) async throws
    func sendHeldNow(_ id: UUID) async throws
    func keepHeldAsDraft(_ id: UUID) async throws

    func planCleanup(_ rows: [ConnectedMailboxRow], action: CleanupAction, account: UUID) async throws -> CleanupPlan
    func runCleanup(_ plan: CleanupPlan, confirmation: CleanupConfirmation) async throws -> CleanupReceipt

    func legacyCredentials() -> [LegacyCredential]
    func assignLegacy(_ items: [LegacyCredential], to account: UUID) async throws
    func legacyRecaptures() async throws -> [LegacyOnlineCapture]
    func compareRecapture(_ old: LegacyOnlineCapture, account: UUID) async throws -> LegacyRecaptureComparison
}

struct MailBackendUnavailable: LocalizedError {
    var errorDescription: String? { String(localized: "This edition has no mail connection code.") }
}

extension MailWorkspaceBackend {
    var providerInfo: [String: String] { [:] }
    func accounts() async throws -> [MailAccountSnapshot] { [] }
    func addIMAP(_ form: MailIMAPForm) async throws -> UUID { throw MailBackendUnavailable() }
    func signIn(_ choice: MailProviderChoice, address: String, existing: UUID?, extraScopes: [String]) async throws -> UUID { throw MailBackendUnavailable() }
    func setMode(_ mode: MailAccount.Mode, enabled: Bool, account: UUID) async throws { throw MailBackendUnavailable() }
    func syncNow(_ account: UUID) async {}
    func setPaused(_ paused: Bool, account: UUID) async throws { throw MailBackendUnavailable() }
    func folders(_ account: UUID) async throws -> [ConnectedFolderSummary] { [] }
    func setFolderSelected(_ serverID: String, selected: Bool, account: UUID) async throws { throw MailBackendUnavailable() }
    func removalPlan(_ account: UUID) async throws -> AccountRemovalPlan { throw MailBackendUnavailable() }
    func remove(_ account: UUID) async throws -> AccountRemovalReport { throw MailBackendUnavailable() }
    func archiveDeletionPlan(_ account: UUID) async throws -> ConnectedAccountArchiveSummary { throw MailBackendUnavailable() }
    func deleteArchivedMail(_ account: UUID, confirmedCount: Int) async throws -> ConnectedAccountArchiveDeletion { throw MailBackendUnavailable() }
    func mailbox(_ query: ConnectedMailboxQuery, after: ConnectedMailboxCursor?) async throws -> ConnectedMailboxPage {
        ConnectedMailboxPage(rows: [], total: 0, next: nil)
    }
    func email(_ id: UUID) async throws -> MBOXParser.RawEmail? { nil }
    func changeOnServer(_ request: RemoteChangeRequest, row: ConnectedMailboxRow) async throws -> RemoteOperation { throw MailBackendUnavailable() }
    func identities(_ account: UUID) async -> [SendingIdentity] { [] }
    func drafts() async -> DraftListing { DraftListing(drafts: [], unreadable: [], unrecordedAttachmentFiles: 0) }
    func createDraft(_ seed: DraftSeed) async throws -> Draft { throw MailBackendUnavailable() }
    func saveDraft(_ draft: Draft) async throws -> Draft { throw MailBackendUnavailable() }
    func discardDraft(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func attachmentAvailability(_ attachment: DraftAttachment, draft: UUID) async -> DraftAttachmentAvailability { .available }
    func addAttachment(_ file: URL, to draft: Draft) async throws -> Draft { throw MailBackendUnavailable() }
    func archivedSource(_ emailID: UUID) async throws -> ArchivedMessageSource { throw MailBackendUnavailable() }
    func queue(_ draft: Draft, undoDelay: TimeInterval) async throws -> OutboxOperation { throw MailBackendUnavailable() }
    func outbox() async throws -> [OutboxOperation] { [] }
    func outboxHolds() async -> [UUID: OutboxHoldReason] { [:] }
    func cancelSend(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func checkSent(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func resendAnyway(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func retryNow(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func sendHeldNow(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func keepHeldAsDraft(_ id: UUID) async throws { throw MailBackendUnavailable() }
    func planCleanup(_ rows: [ConnectedMailboxRow], action: CleanupAction, account: UUID) async throws -> CleanupPlan { throw MailBackendUnavailable() }
    func runCleanup(_ plan: CleanupPlan, confirmation: CleanupConfirmation) async throws -> CleanupReceipt { throw MailBackendUnavailable() }
    func legacyCredentials() -> [LegacyCredential] { [] }
    func assignLegacy(_ items: [LegacyCredential], to account: UUID) async throws { throw MailBackendUnavailable() }
    func legacyRecaptures() async throws -> [LegacyOnlineCapture] { [] }
    func compareRecapture(_ old: LegacyOnlineCapture, account: UUID) async throws -> LegacyRecaptureComparison { throw MailBackendUnavailable() }
}

/// The backend of a build (or a moment) without connected mail: it says why
/// and offers nothing.
@MainActor
final class UnavailableMailBackend: MailWorkspaceBackend {
    let availability: MailWorkspaceAvailability
    init(_ availability: MailWorkspaceAvailability) { self.availability = availability }
}

// MARK: - Model

@MainActor
@Observable
final class MailWorkspaceModel {
    enum Section: Hashable {
        case unifiedInbox
        case account(UUID)
        case folder(UUID, String)
        case drafts
        case outbox
        case accounts
    }

    let backend: MailWorkspaceBackend
    var section: Section = .unifiedInbox
    private(set) var accounts: [MailAccountSnapshot] = []
    private(set) var folders: [UUID: [ConnectedFolderSummary]] = [:]
    private(set) var rows: [ConnectedMailboxRow] = []
    private(set) var total = 0
    private var nextCursor: ConnectedMailboxCursor?
    var unreadOnly = false { didSet { if oldValue != unreadOnly { Task { await reloadMailbox() } } } }
    var flaggedOnly = false { didSet { if oldValue != flaggedOnly { Task { await reloadMailbox() } } } }
    var selectedMessage: UUID?
    /// The account shown in "Accounts and status".
    var selectedAccount: UUID?
    private(set) var drafts: [Draft] = []
    private(set) var unreadableDrafts = 0
    private(set) var outbox: [OutboxOperation] = []
    private(set) var holds: [UUID: OutboxHoldReason] = [:]
    /// The last plain-language result of an action (shown in a status line).
    var message: String?
    /// A mode or action needs a scope the account has not granted yet.
    var pendingReconsent: MailReconsentRequest?
    var lastError: String?
    var busy = false

    /// Some account is saving mail right now (Sync now, the launch sync, an automatic retry).
    var anyRunning: Bool { accounts.contains(where: \.isRunning) }

    init(backend: MailWorkspaceBackend) {
        self.backend = backend
    }

    var availability: MailWorkspaceAvailability { backend.availability }

    /// Empty unless mail can actually do something here.
    var actions: [MailWorkspaceAction] {
        guard availability == .ready else { return [] }
        var out: [MailWorkspaceAction] = [.addAccount, .openOutbox]
        if accounts.contains(where: { $0.account.enabledModes.contains(.capture) && $0.account.connectionState == .connected }) {
            out.append(.syncNow)
        }
        if accounts.contains(where: { $0.account.enabledModes.contains(.send) }) { out.append(.compose) }
        if accounts.contains(where: { $0.account.enabledModes.contains(.serverActions) }) { out.append(.cleanup) }
        return out
    }

    /// V4-16: the providers Add account lists (one Gmail entry, by the build's mode).
    var offeredProviders: [MailProviderChoice] { MailProviderChoice.offered(info: backend.providerInfo) }

    func providerReadiness(_ choice: MailProviderChoice) -> MailProviderChoice.Readiness {
        guard availability == .ready else { return .unavailable(availability.title) }
        return choice.readiness(info: backend.providerInfo)
    }

    var hasMoreRows: Bool { nextCursor != nil }

    func account(_ id: UUID) -> MailAccountSnapshot? { accounts.first { $0.id == id } }

    // MARK: Loading

    /// Reloads accounts, mailbox, drafts and outbox. A reload never clears
    /// an error an action just showed (it only reports its own failure).
    func refresh() async {
        guard availability == .ready else { accounts = []; rows = []; return }
        await refreshAccounts()
        await reloadMailbox()
        await reloadDrafts()
        await reloadOutbox()
    }

    /// Accounts and their folders only — what a running capture's progress changes.
    func refreshAccounts() async {
        guard availability == .ready else { accounts = []; return }
        await run(clearsError: false) {
            self.accounts = try await self.backend.accounts().filter { $0.account.connectionState != .removed }
            for a in self.accounts { self.folders[a.id] = try await self.backend.folders(a.id) }
        }
    }

    var currentQuery: ConnectedMailboxQuery {
        switch section {
        case .account(let id): return ConnectedMailboxQuery(accountIDs: [id], unreadOnly: unreadOnly, flaggedOnly: flaggedOnly)
        case .folder(let id, let folder):
            return ConnectedMailboxQuery(accountIDs: [id], folderServerID: folder, unreadOnly: unreadOnly, flaggedOnly: flaggedOnly)
        default:
            return ConnectedMailboxQuery(accountIDs: Set(accounts.map(\.id)), unreadOnly: unreadOnly, flaggedOnly: flaggedOnly)
        }
    }

    func reloadMailbox() async {
        guard availability == .ready else { return }
        await run(clearsError: false) {
            let page = try await self.backend.mailbox(self.currentQuery, after: nil)
            self.rows = page.rows; self.total = page.total; self.nextCursor = page.next
        }
    }

    /// The next page, on request ("Show more"): no hidden cap.
    func loadMore() async {
        guard let cursor = nextCursor else { return }
        await run(clearsError: false) {
            let page = try await self.backend.mailbox(self.currentQuery, after: cursor)
            self.rows += page.rows; self.total = page.total; self.nextCursor = page.next
        }
    }

    var showingCountText: String {
        String(localized: "Showing \(rows.count) of \(total) messages")
    }

    func reloadDrafts() async {
        let listing = await backend.drafts()
        drafts = listing.drafts.sorted { $0.updatedAt > $1.updatedAt }
        unreadableDrafts = listing.unreadable.count
    }

    func reloadOutbox() async {
        await run(clearsError: false) {
            self.outbox = try await self.backend.outbox().sorted { $0.createdAt > $1.createdAt }
        }
        holds = await backend.outboxHolds()
    }

    // MARK: Accounts

    func setMode(_ mode: MailAccount.Mode, enabled: Bool, account: UUID) async {
        if enabled, let a = self.account(account)?.account, let why = MailModeText.unavailableReason(mode, account: a) {
            lastError = why
            return
        }
        await run {
            try await self.backend.setMode(mode, enabled: enabled, account: account)
            self.accounts = try await self.backend.accounts().filter { $0.account.connectionState != .removed }
            if enabled, let a = self.account(account)?.account, let scope = MailScopeNeeds.missing(mode, account: a) {
                self.pendingReconsent = MailReconsentRequest(accountID: account, scope: scope, mode: mode)
            } else if mode == .capture, enabled {
                self.message = String(localized: "Preserve mail is on. Saving has started; the account shows its progress.")
            }
        }
    }

    /// Adds an IMAP account (nothing allowed yet) and selects it.
    func addIMAP(_ form: MailIMAPForm) async -> Bool {
        var ok = false
        await run {
            let id = try await self.backend.addIMAP(form)
            self.message = String(localized: "Account added. Nothing is downloaded until you turn on Preserve mail.")
            self.section = .account(id)
            ok = true
        }
        if ok { await refresh() }
        return ok
    }

    /// Signs in a new OAuth account (nothing allowed yet). Does nothing when
    /// the provider's sign-in is not configured in this build.
    func signIn(_ choice: MailProviderChoice, address: String) async -> Bool {
        guard providerReadiness(choice).isReady else { return false }
        var ok = false
        await run {
            let id = try await self.backend.signIn(choice, address: address, existing: nil, extraScopes: [])
            var note = String(localized: "Account added. Nothing is downloaded until you turn on Preserve mail.")
            let typed = address.trimmingCharacters(in: .whitespaces)
            if let added = try await self.backend.accounts().first(where: { $0.id == id })?.account {
                if added.displayIdentity.lowercased() != typed.lowercased() {
                    note += " " + String(localized: "The provider says this account's address is \(added.displayIdentity), so mailin uses that instead of \(typed).")
                }
                let identities = await self.backend.identities(id)
                if !identities.isEmpty, !identities.contains(where: { $0.permission == .verified }) {
                    note += " " + String(localized: "The provider did not confirm this account's address, so mailin will not send from it.")
                }
            }
            self.message = note
            self.section = .account(id)
            ok = true
        }
        if ok { await refresh() }
        return ok
    }

    /// An account whose capture already runs is left to it (no second run,
    /// no "did not start" report).
    func syncNow(_ account: UUID? = nil) async {
        let ids = (account.map { [$0] } ?? accounts.filter { $0.account.enabledModes.contains(.capture) }.map(\.id))
            .filter { id in self.account(id)?.isRunning != true }
        busy = true
        for id in ids { await backend.syncNow(id) }
        busy = false
        await refresh()
    }

    func setPaused(_ paused: Bool, account: UUID) async {
        await run { try await self.backend.setPaused(paused, account: account) }
        await refresh()
    }

    func setFolderSelected(_ folder: ConnectedFolderSummary, selected: Bool) async {
        await run {
            try await self.backend.setFolderSelected(folder.serverID, selected: selected, account: folder.accountID)
            self.folders[folder.accountID] = try await self.backend.folders(folder.accountID)
        }
    }

    // MARK: Removal

    func removalPlan(_ account: UUID) async -> AccountRemovalPlan? {
        var plan: AccountRemovalPlan?
        await run { plan = try await self.backend.removalPlan(account) }
        return plan
    }

    /// Removes the account; archived mail is kept (deletion is separate).
    func remove(_ account: UUID) async -> AccountRemovalReport? {
        var report: AccountRemovalReport?
        await run {
            let r = try await self.backend.remove(account)
            report = r
            self.message = MailRemovalText.report(r)
        }
        if section == .account(account) { section = .unifiedInbox }
        await refresh()
        return report
    }

    func deleteArchivedMail(_ account: UUID, confirmedCount: Int) async -> ConnectedAccountArchiveDeletion? {
        var result: ConnectedAccountArchiveDeletion?
        await run {
            let r = try await self.backend.deleteArchivedMail(account, confirmedCount: confirmedCount)
            result = r
            self.message = String(localized: "\(r.deletedEmailIDs.count) archived messages deleted; \(r.heldKept) on hold kept.")
        }
        return result
    }

    // MARK: Server changes

    /// Only when the account allows Change server mail AND the person chose
    /// it: opening a message never changes anything on the server.
    func canChangeOnServer(_ row: ConnectedMailboxRow) -> Bool {
        guard let a = account(row.accountID)?.account else { return false }
        return a.enabledModes.contains(.serverActions) && a.connectionState == .connected && row.onServer
    }

    /// Returns the scope to re-consent to, when that was the refusal.
    @discardableResult
    func changeOnServer(_ request: RemoteChangeRequest, row: ConnectedMailboxRow) async -> String? {
        guard canChangeOnServer(row) else {
            message = MailServerChangeText.rejection(.changeServerMailOff)
            return nil
        }
        var scope: String?
        await run {
            let op = try await self.backend.changeOnServer(request, row: row)
            self.message = MailServerChangeText.outcome(op.outcome)
            scope = MailServerChangeText.missingScope(op.outcome)
        }
        if let scope { pendingReconsent = MailReconsentRequest(accountID: row.accountID, scope: scope, mode: .serverActions) }
        return scope
    }

    /// Signs in again asking for `scope`. Says "with the extra permission"
    /// only when the provider's answer really contains it; otherwise the mode
    /// that needed it is switched off again and the page says so. Its error
    /// stays on screen (the reload after it does not clear it).
    func reconsent(_ account: UUID, scope: String, mode: MailAccount.Mode? = nil) async {
        guard let snapshot = self.account(account) else { return }
        let choice: MailProviderChoice = snapshot.account.provider == .gmail ? .gmail : .outlook
        pendingReconsent = nil
        var signedIn = false
        await run {
            _ = try await self.backend.signIn(choice, address: snapshot.account.displayIdentity, existing: account, extraScopes: [scope])
            signedIn = true
        }
        let after = try? await backend.accounts().first(where: { $0.id == account })?.account
        let granted = signedIn && after.map { MailReconsentRequest.granted(scope, in: $0.grantedScopes) } == true
        if granted {
            message = mode == nil
                ? String(localized: "Signed in again.")
                : String(localized: "Signed in again with the extra permission.")
        } else if let mode, mode != .capture {
            await switchOff(mode, account: account)
            let staysOff = String(localized: "The extra permission was not granted, so \(MailModeText.title(mode)) stays off.")
            lastError = signedIn ? staysOff : [lastError, staysOff].compactMap { $0 }.joined(separator: " ")
        } else if signedIn {
            lastError = String(localized: "The provider did not grant the permission that was asked for.")
        }
        await refresh()
    }

    /// "Not now" on the extra-permission question: the mode that needed it
    /// is switched off again, so no account says "Send mail" while it cannot send.
    func declineReconsent(_ asked: MailReconsentRequest? = nil) async {
        guard let request = asked ?? pendingReconsent else { return }
        pendingReconsent = nil
        guard let mode = request.mode, mode != .capture else { return }
        await switchOff(mode, account: request.accountID)
        message = String(localized: "\(MailModeText.title(mode)) stays off until you allow the extra permission.")
        await refreshAccounts()
    }

    private func switchOff(_ mode: MailAccount.Mode, account: UUID) async {
        guard self.account(account)?.account.enabledModes.contains(mode) == true else { return }
        do { try await backend.setMode(mode, enabled: false, account: account) } catch {
            lastError = ConnectedMailErrorText.text(for: error)
        }
    }

    // MARK: Outbox

    func outboxAction(_ body: @MainActor () async throws -> Void) async {
        await run { try await body() }
        await reloadOutbox()
    }

    // MARK: Helpers

    /// Runs one step; a failure shows as a plain sentence (never a raw error).
    /// `clearsError` false for reloads: they never wipe an action's error.
    func run(clearsError: Bool = true, _ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            if clearsError { lastError = nil }
        } catch {
            lastError = ConnectedMailErrorText.text(for: error)
        }
    }
}
