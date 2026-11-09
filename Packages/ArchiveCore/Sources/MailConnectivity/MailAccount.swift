//
//  MailAccount.swift
//  MailConnectivity
//
//  Plan v4 V4-02 (§3 A15/A16, §5.1): one connected account, identified by a
//  UUID and its provider/issuer/tenant or server — never by a user name
//  alone. Persisted in the archive (`mail_accounts`, schema v26) through
//  `ConnectedAccountRecordStore`; secrets stay in a `CredentialStore` keyed
//  by the same UUID. Every save is one transaction and every failure is
//  thrown to the caller (the old branch's registry swallowed save errors).
//

import ArchiveCore
import Foundation

public struct MailAccount: Sendable, Equatable, Identifiable {
    public enum Mode: String, Sendable, Codable, CaseIterable, Comparable {
        case capture, send, serverActions
        public static func < (a: Mode, b: Mode) -> Bool { a.rawValue < b.rawValue }
    }

    public enum ConnectionState: String, Sendable, Codable {
        case connected
        /// Sign in again: no usable credential (revoked, restored on another
        /// device, never stored, or refresh refused).
        case needsReauthorisation
        case disconnected
        /// Removed by the user: secrets deleted, archived mail kept.
        case removed
    }

    public let id: UUID
    public var provider: MailProviderKind
    /// OAuth issuer (Gmail: https://accounts.google.com; Microsoft:
    /// https://login.microsoftonline.com/<tenant>/v2.0). Empty for IMAP.
    public var issuer: String
    public var tenant: String?
    /// IMAP server identity.
    public var host: String?
    public var port: Int?
    /// IMAP login name — an identifier, not a secret, and NOT the account key.
    public var loginName: String?
    /// The address shown for the account.
    public var displayIdentity: String
    public var grantedScopes: [String]
    public var enabledModes: Set<Mode>
    public var connectionState: ConnectionState
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the credential store could not be read while listing — the
    /// account is listed (never hidden), with the reason.
    public var credentialIssue: String?

    public init(id: UUID = UUID(), provider: MailProviderKind, issuer: String = "", tenant: String? = nil,
                host: String? = nil, port: Int? = nil, loginName: String? = nil, displayIdentity: String,
                grantedScopes: [String] = [], enabledModes: Set<Mode> = [.capture],
                connectionState: ConnectionState = .disconnected, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.provider = provider; self.issuer = issuer; self.tenant = tenant
        self.host = host; self.port = port; self.loginName = loginName; self.displayIdentity = displayIdentity
        self.grantedScopes = grantedScopes; self.enabledModes = enabledModes; self.connectionState = connectionState
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Who the account is at: issuer (+ tenant) for OAuth providers,
    /// host:port for IMAP.
    public var serverIdentity: String {
        switch provider {
        case .gmail: return issuer
        case .microsoftGraph: return tenant.map { "\(issuer)#\($0)" } ?? issuer
        case .imap: return "\(host ?? ""):\(port ?? 993)"
        }
    }

    /// The minimum an account needs to be addressable without ambiguity.
    public func validate() throws {
        switch provider {
        case .gmail, .microsoftGraph:
            guard !issuer.isEmpty else { throw MailAccountError.incomplete("an OAuth account needs its issuer") }
        case .imap:
            guard let host, !host.isEmpty else { throw MailAccountError.incomplete("an IMAP account needs its server") }
        }
        guard !displayIdentity.isEmpty else { throw MailAccountError.incomplete("an account needs its address") }
    }

    var record: ConnectedAccountRecord {
        ConnectedAccountRecord(accountID: id, provider: provider, issuer: issuer, tenant: tenant, host: host, port: port,
                               loginName: loginName, displayIdentity: displayIdentity, grantedScopes: grantedScopes,
                               enabledModes: enabledModes.sorted().map(\.rawValue), connectionState: connectionState.rawValue,
                               createdAt: createdAt, updatedAt: updatedAt)
    }

    init(record r: ConnectedAccountRecord) throws {
        guard let state = ConnectionState(rawValue: r.connectionState) else {
            throw MailAccountError.corruptRecord("account \(r.accountID) has an unknown state “\(r.connectionState)”")
        }
        var modes = Set<Mode>()
        for raw in r.enabledModes {
            guard let mode = Mode(rawValue: raw) else { throw MailAccountError.corruptRecord("account \(r.accountID) has an unknown mode “\(raw)”") }
            modes.insert(mode)
        }
        self.init(id: r.accountID, provider: r.provider, issuer: r.issuer, tenant: r.tenant, host: r.host, port: r.port,
                  loginName: r.loginName, displayIdentity: r.displayIdentity, grantedScopes: r.grantedScopes,
                  enabledModes: modes, connectionState: state, createdAt: r.createdAt, updatedAt: r.updatedAt)
    }
}

public enum MailAccountError: LocalizedError, Equatable {
    case incomplete(String)
    case corruptRecord(String)
    case unknownAccount(UUID)
    /// The record could not be saved; the secret written for it was removed again.
    case saveFailed(String)
    /// The record could not be saved AND the secret written for it could not be removed.
    case saveFailedSecretLeft(save: String, cleanup: String)

    public var errorDescription: String? {
        switch self {
        case .incomplete(let why): return "The account is incomplete: \(why)."
        case .corruptRecord(let why): return "A saved account could not be read: \(why)."
        case .unknownAccount(let id): return "No account \(id.uuidString)."
        case .saveFailed(let why): return "The account was not added: \(why)"
        case .saveFailedSecretLeft(let save, let cleanup): return "The account was not added (\(save)), and its sign-in details could not be removed from the Keychain (\(cleanup))."
        }
    }
}

/// Accounts and their secrets, kept consistent. An actor, so two saves of
/// one account never interleave.
public actor MailAccountRegistry {
    let records: ConnectedAccountRecordStore
    let credentials: CredentialStore

    public init(records: ConnectedAccountRecordStore, credentials: CredentialStore) {
        self.records = records
        self.credentials = credentials
    }

    /// Every account, with its EFFECTIVE state: an account stored as
    /// connected whose secret is absent (a restore on another device, a
    /// removed Keychain item) is `needsReauthorisation`. A credential store
    /// that cannot be read is reported on the account, never hidden.
    public func accounts() async throws -> [MailAccount] {
        var out: [MailAccount] = []
        for record in try await records.accountRecords() {
            var account = try MailAccount(record: record)
            if account.connectionState == .connected {
                do {
                    if try !hasAnySecret(account.id) { account.connectionState = .needsReauthorisation }
                } catch {
                    account.connectionState = .needsReauthorisation
                    account.credentialIssue = error.localizedDescription
                }
            }
            out.append(account)
        }
        return out
    }

    public func account(_ id: UUID) async throws -> MailAccount {
        guard let account = try await accounts().first(where: { $0.id == id }) else { throw MailAccountError.unknownAccount(id) }
        return account
    }

    private func hasAnySecret(_ id: UUID) throws -> Bool {
        for kind in CredentialKind.allCases where try credentials.read(kind, account: id) != nil { return true }
        return false
    }

    /// Adds (or reconnects) an account with its secret. Order: the secret is
    /// written first (account-scoped); then the record commits. If the record
    /// cannot be saved, the secret is removed again — no half-added account,
    /// and no account that claims to be connected without a secret.
    public func add(_ account: MailAccount, secret: Data, kind: CredentialKind) async throws {
        try account.validate()
        try credentials.write(secret, kind: kind, account: account.id)
        var saved = account
        saved.connectionState = .connected
        saved.updatedAt = Date()
        do {
            try await records.saveAccount(saved.record)
        } catch {
            do { try credentials.delete(kind, account: account.id) } catch let cleanup {
                throw MailAccountError.saveFailedSecretLeft(save: error.localizedDescription, cleanup: cleanup.localizedDescription)
            }
            throw MailAccountError.saveFailed(error.localizedDescription)
        }
    }

    /// Saves metadata only (modes, display identity, scopes, state).
    public func save(_ account: MailAccount) async throws {
        try account.validate()
        var saved = account
        saved.updatedAt = Date()
        try await records.saveAccount(saved.record)
    }

    /// Replaces a secret. On failure the previous secret is kept and the error thrown.
    public func updateSecret(_ secret: Data, kind: CredentialKind, account id: UUID) throws {
        try credentials.write(secret, kind: kind, account: id)
    }

    public func setState(_ state: MailAccount.ConnectionState, account id: UUID) async throws {
        var account = try await account(id)
        account.connectionState = state
        try await save(account)
    }

    /// Removes the account's secrets and marks it removed. Archived messages,
    /// folders and their provenance stay (§7 Account removal); no other
    /// account is touched.
    public func remove(_ id: UUID) async throws {
        var account = try await account(id)
        for kind in CredentialKind.allCases { try credentials.delete(kind, account: id) }
        account.connectionState = .removed
        account.enabledModes = []
        try await save(account)
    }
}
