//
//  LegacyUpgrade.swift
//  MailConnectivity
//
//  Plan v4 V4-12 (§7 Upgrade, T46): what a pre-v4 install left behind.
//
//  1. Singleton SETTINGS in UserDefaults — one global compose draft
//     (`compose_draft`), one IMAP server (`imap_server/_port/_username`), one
//     SMTP server (`smtp_server/_port/_username/_from`). Like the old global
//     Keychain items (`LegacyCredentialInventory`) they name no account, so
//     they are listed and migrated ONLY by the user's explicit choice of an
//     account, confirmed with exactly those keys. Nothing is migrated on
//     launch and nothing old is deleted by a migration (rule 1); retiring the
//     old keys is a separate call.
//
//  2. Earlier, incomplete online CAPTURES — the old Gmail connector stored
//     fields without the message source (rawSource ""), the old Outlook
//     connector a pseudo-source rebuilt from Graph fields; both through the
//     unscoped `ingestEmails` path (no source, no account). They are listed
//     page by page (`LegacyRecapturePlanner.inventory`), offered for
//     source-based recapture by a normal capture of the chosen account, and
//     compared field by field with the recaptured record. The old record is
//     never replaced, changed or deleted: both stay, and the user's choice
//     (keep both / prefer the recaptured copy) is recorded in the lifecycle
//     ledger.
//

import ArchiveCore
import Foundation

// MARK: - Settings

/// Reads the old singleton settings (UserDefaults conforms; tests inject a dictionary).
public protocol LegacySettingsReading {
    func object(forKey key: String) -> Any?
    func removeObject(forKey key: String)
}

extension UserDefaults: LegacySettingsReading {}

public struct LegacySetting: Sendable, Equatable, Hashable {
    public enum Purpose: String, Sendable { case composeDraft, imapServer, smtpServer }
    public let key: String
    public let purpose: Purpose
}

/// The user's explicit choice: these old settings belong to this account.
public struct LegacySettingConfirmation: Sendable, Equatable {
    public let accountID: UUID
    public let keys: Set<String>
    public init(accountID: UUID, keys: Set<String>) { self.accountID = accountID; self.keys = keys }
}

public enum LegacySettingError: LocalizedError, Equatable {
    case notConfirmed
    case providerMismatch
    case absent(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfirmed: return "Choose the account these old settings belong to and confirm it."
        case .providerMismatch: return "These old settings are for a different kind of account."
        case .absent(let key): return "The old setting \(key) is no longer there."
        case .unreadable(let why): return "The old setting could not be read: \(why)."
        }
    }
}

/// What the old compose draft held (shown before it is migrated).
public struct LegacyComposeDraft: Sendable, Equatable {
    public var to: String, cc: String, bcc: String, subject: String, body: String, from: String
}

public struct LegacySettingsInventory {
    public static let composeDraftKey = "compose_draft"
    public static let imapKeys = ["imap_server", "imap_port", "imap_username"]
    public static let smtpKeys = ["smtp_server", "smtp_port", "smtp_username", "smtp_from"]

    let defaults: LegacySettingsReading
    public init(defaults: LegacySettingsReading = UserDefaults.standard) { self.defaults = defaults }

    private func present(_ key: String) -> Bool {
        switch defaults.object(forKey: key) {
        case nil: return false
        case let s as String: return !s.isEmpty
        case let d as Data: return !d.isEmpty
        default: return true
        }
    }

    /// The old settings present now. Nothing is changed by listing them.
    public func items() -> [LegacySetting] {
        var out: [LegacySetting] = []
        if present(Self.composeDraftKey) { out.append(.init(key: Self.composeDraftKey, purpose: .composeDraft)) }
        out += Self.imapKeys.filter(present).map { .init(key: $0, purpose: .imapServer) }
        out += Self.smtpKeys.filter(present).map { .init(key: $0, purpose: .smtpServer) }
        return out
    }

    private func keys(_ purpose: LegacySetting.Purpose) -> Set<String> { Set(items().filter { $0.purpose == purpose }.map(\.key)) }

    private func check(_ confirmation: LegacySettingConfirmation, account: MailAccount, purpose: LegacySetting.Purpose) throws {
        let expected = keys(purpose)
        guard !expected.isEmpty else { throw LegacySettingError.absent(purpose.rawValue) }
        guard confirmation.accountID == account.id, confirmation.keys == expected else { throw LegacySettingError.notConfirmed }
    }

    private func string(_ key: String) -> String? {
        switch defaults.object(forKey: key) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    // MARK: Compose draft

    public func composeDraft() throws -> LegacyComposeDraft? {
        guard let raw = defaults.object(forKey: Self.composeDraftKey) else { return nil }
        guard let data = raw as? Data else { throw LegacySettingError.unreadable("compose_draft is not data") }
        let fields: [String: String]
        do { fields = try JSONDecoder().decode([String: String].self, from: data) } catch {
            throw LegacySettingError.unreadable(error.localizedDescription)
        }
        return LegacyComposeDraft(to: fields["to"] ?? "", cc: fields["cc"] ?? "", bcc: fields["bcc"] ?? "",
                                  subject: fields["subject"] ?? "", body: fields["body"] ?? "", from: fields["from"] ?? "")
    }

    /// Copies the old compose draft into a durable draft of `account` — only
    /// with a confirmation naming that account and `compose_draft`. The
    /// sending identity is left for the user to choose (the old "from" text
    /// is never turned into an identity). The old setting stays.
    public func migrateComposeDraft(to account: MailAccount, confirmation: LegacySettingConfirmation,
                                    into drafts: DraftStore) async throws -> Draft {
        try check(confirmation, account: account, purpose: .composeDraft)
        guard let old = try composeDraft() else { throw LegacySettingError.absent(Self.composeDraftKey) }
        func list(_ text: String) throws -> [MailAddress] {
            text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : try MailAddressParser.parseList(text)
        }
        let draft = Draft(accountID: account.id, to: try list(old.to), cc: try list(old.cc), bcc: try list(old.bcc),
                          subject: old.subject, plainBody: old.body)
        return try await drafts.save(draft)
    }

    // MARK: Server settings

    /// The IMAP account the old settings describe — not saved.
    public func proposedIMAPAccount() -> MailAccount? {
        guard let host = string("imap_server"), !host.isEmpty else { return nil }
        let login = string("imap_username")
        let port = string("imap_port").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 993
        let identity = (login?.contains("@") == true ? login : string("smtp_from")) ?? login ?? host
        return MailAccount(provider: .imap, host: host, port: port, loginName: login, displayIdentity: identity,
                           enabledModes: [.capture], connectionState: .needsReauthorisation)
    }

    /// Saves the confirmed IMAP account (no password: the old one is copied
    /// only through `LegacyCredentialInventory.assign`, also by explicit choice).
    public func migrateIMAPSettings(to account: MailAccount, confirmation: LegacySettingConfirmation,
                                    registry: MailAccountRegistry) async throws -> MailAccount {
        guard account.provider == .imap else { throw LegacySettingError.providerMismatch }
        try check(confirmation, account: account, purpose: .imapServer)
        var saved = account
        saved.connectionState = .needsReauthorisation
        try await registry.save(saved)
        return saved
    }

    /// The SMTP route the old settings describe, for the account the user confirms.
    public func confirmedSMTPSettings(for account: MailAccount, confirmation: LegacySettingConfirmation) throws -> (settings: SMTPServerSettings, username: String?, from: String?) {
        try check(confirmation, account: account, purpose: .smtpServer)
        guard let host = string("smtp_server"), !host.isEmpty else { throw LegacySettingError.absent("smtp_server") }
        let port = string("smtp_port").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 587
        return (SMTPServerSettings(host: host, port: port, security: port == 465 ? .implicitTLS : .startTLS),
                string("smtp_username"), string("smtp_from"))
    }

    /// Removes old keys — a separate, explicit step after migration.
    public func retire(_ settings: [LegacySetting]) {
        for s in settings { defaults.removeObject(forKey: s.key) }
    }
}

// MARK: - Earlier online captures

public struct LegacyCaptureInventory: Sendable, Equatable {
    public var gmailWithoutSource = 0
    public var outlookPseudoSource = 0
    public var noSourceUnknownOrigin = 0
    public var total: Int { gmailWithoutSource + outlookPseudoSource + noSourceUnknownOrigin }
}

public struct LegacyRecaptureComparison: Sendable, Equatable {
    public enum Field: String, Sendable { case subject, from, date, body, attachments }
    public enum Verdict: Sendable, Equatable {
        /// The old record has no Message-ID: it cannot be matched automatically.
        case noMessageID
        /// The account has no source-based record with this Message-ID yet (capture it first).
        case notRecapturedYet
        /// Matched: the fields that differ (empty = the same content; the
        /// recaptured record also has the real source).
        case recaptured(UUID, differences: [Field])
        /// Several recaptured records carry the Message-ID: the user picks.
        case ambiguous([UUID])
    }
    public var old: ArchivedMessageSummary
    public var recaptured: ArchivedMessageSummary?
    public var verdict: Verdict
}

public enum LegacyRecaptureError: LocalizedError, Equatable {
    case providerMismatch(LegacyOnlineCapture.Kind, MailProviderKind)
    case recordMissing(UUID)
    public var errorDescription: String? {
        switch self {
        case .providerMismatch(let kind, let provider): return "An old \(kind.rawValue) record cannot be compared with a \(provider.rawValue) account."
        case .recordMissing(let id): return "Message \(id.uuidString) is no longer in the archive."
        }
    }
}

public struct LegacyRecapturePlanner: Sendable {
    let sink: ConnectedArchiveSink
    let lifecycle: ConnectedLifecycle
    public let pageSize: Int

    public init(sink: ConnectedArchiveSink, lifecycle: ConnectedLifecycle, pageSize: Int = 500) {
        self.sink = sink; self.lifecycle = lifecycle; self.pageSize = max(1, pageSize)
    }

    /// Counts every incomplete earlier capture, page by page (no cap);
    /// `each` sees every record (the app lists them).
    public func inventory(_ each: (@Sendable (LegacyOnlineCapture) -> Void)? = nil) async throws -> LegacyCaptureInventory {
        var out = LegacyCaptureInventory()
        var after: UUID?
        while true {
            let page = try await sink.legacyOnlineCaptures(after: after, limit: pageSize)
            for item in page {
                switch item.kind {
                case .gmailWithoutSource: out.gmailWithoutSource += 1
                case .outlookPseudoSource: out.outlookPseudoSource += 1
                case .noSourceUnknownOrigin: out.noSourceUnknownOrigin += 1
                }
                each?(item)
            }
            guard page.count == pageSize, let last = page.last else { return out }
            after = last.emailID
        }
    }

    static func compatible(_ kind: LegacyOnlineCapture.Kind, _ provider: MailProviderKind) -> Bool {
        switch kind {
        case .gmailWithoutSource: return provider == .gmail
        case .outlookPseudoSource: return provider == .microsoftGraph
        case .noSourceUnknownOrigin: return true
        }
    }

    /// Compares an old record with the account's source-based recapture.
    public func compare(_ old: LegacyOnlineCapture, account: MailAccount) async throws -> LegacyRecaptureComparison {
        guard Self.compatible(old.kind, account.provider) else { throw LegacyRecaptureError.providerMismatch(old.kind, account.provider) }
        guard let oldSummary = try await sink.messageSummary(emailID: old.emailID) else { throw LegacyRecaptureError.recordMissing(old.emailID) }
        guard let messageID = old.messageID, !messageID.isEmpty else {
            return LegacyRecaptureComparison(old: oldSummary, recaptured: nil, verdict: .noMessageID)
        }
        let candidates = try await sink.connectedRecords(accountID: account.id, messageID: messageID)
        guard let first = candidates.first else { return LegacyRecaptureComparison(old: oldSummary, recaptured: nil, verdict: .notRecapturedYet) }
        guard candidates.count == 1 else { return LegacyRecaptureComparison(old: oldSummary, recaptured: nil, verdict: .ambiguous(candidates)) }
        guard let new = try await sink.messageSummary(emailID: first) else { throw LegacyRecaptureError.recordMissing(first) }
        var differences: [LegacyRecaptureComparison.Field] = []
        if oldSummary.subject != new.subject { differences.append(.subject) }
        if oldSummary.from != new.from { differences.append(.from) }
        if abs(oldSummary.date.timeIntervalSince(new.date)) > 1 { differences.append(.date) }
        if oldSummary.bodyTextSHA256 != new.bodyTextSHA256 { differences.append(.body) }
        if oldSummary.attachmentNames.sorted() != new.attachmentNames.sorted() { differences.append(.attachments) }
        return LegacyRecaptureComparison(old: oldSummary, recaptured: new, verdict: .recaptured(first, differences: differences))
    }

    /// Records the user's choice. Neither record is changed or deleted.
    public func decide(old: UUID, recaptured: UUID, choice: RecaptureDecision.Choice) throws {
        try lifecycle.recordRecaptureDecision(RecaptureDecision(oldEmailID: old, recapturedEmailID: recaptured, choice: choice, decidedAt: Date()))
    }
}
