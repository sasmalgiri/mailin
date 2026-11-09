//
//  LegacyCredentials.swift
//  MailConnectivity
//
//  Plan v4 V4-02 / T46 (§7 Upgrade): before v4 the app kept ONE global
//  Gmail token set, ONE Outlook token set, ONE IMAP password and ONE SMTP
//  password under fixed Keychain keys (`KeychainHelper`, service
//  `com.ecosanskriti.mailin`). They say nothing about which account they
//  belong to, so they are NEVER assigned to an account automatically — not to
//  the first account, not to the selected one. They are listed as
//  "unassigned legacy credentials"; the user picks the account explicitly,
//  and the copy is made only with a confirmation naming that account and
//  those keys. The old items are not deleted by the copy (rule 1); retiring
//  them is a separate, explicit call.
//

import ArchiveCore
import Foundation
import Security

public struct LegacyCredential: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case accessToken, refreshToken, tokenExpiry, password }
    public enum Purpose: String, Sendable { case gmailSignIn, outlookSignIn, imapPassword, smtpPassword }
    public var id: String { key }
    /// The old global Keychain key (no secret value is ever exposed here).
    public let key: String
    public let purpose: Purpose
    public let kind: Kind

    /// The provider family the key could belong to.
    public var provider: MailProviderKind {
        switch purpose {
        case .gmailSignIn: return .gmail
        case .outlookSignIn: return .microsoftGraph
        case .imapPassword, .smtpPassword: return .imap
        }
    }
}

/// Reads the legacy global items (injectable for tests).
public protocol LegacyKeychainReading: Sendable {
    func read(key: String) throws -> Data?
    func delete(key: String) throws
}

public struct SystemLegacyKeychain: LegacyKeychainReading {
    public static let service = "com.ecosanskriti.mailin"
    let api: KeychainAPI
    public init(api: KeychainAPI = SystemKeychain()) { self.api = api }

    func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: key]
    }

    public func read(key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = api.copyMatching(q)
        switch status {
        case errSecSuccess: return data
        case errSecItemNotFound: return nil
        default: throw CredentialStoreError.keychain(operation: "read", status: status)
        }
    }

    public func delete(key: String) throws {
        let status = api.delete(query(key))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(operation: "removed", status: status)
        }
    }
}

/// The user's explicit choice: these legacy keys belong to this account.
public struct LegacyAssignmentConfirmation: Sendable, Equatable {
    public let accountID: UUID
    public let keys: Set<String>
    public init(accountID: UUID, keys: Set<String>) { self.accountID = accountID; self.keys = keys }
}

public enum LegacyCredentialError: LocalizedError, Equatable {
    case notConfirmed
    case providerMismatch(key: String)
    case mixedPurposes
    case missing(key: String)
    case unreadable(key: String)

    public var errorDescription: String? {
        switch self {
        case .notConfirmed: return "Choose the account these old sign-in details belong to and confirm it."
        case .providerMismatch(let key): return "The old sign-in detail \(key) is for a different kind of account."
        case .mixedPurposes: return "Assign the old sign-in details of one service at a time."
        case .missing(let key): return "The old sign-in detail \(key) is no longer in the Keychain."
        case .unreadable(let key): return "The old sign-in detail \(key) could not be understood."
        }
    }
}

public struct LegacyCredentialInventory: Sendable {
    /// Every global key a pre-v4 build wrote (`KeychainHelper`).
    public static let knownKeys: [LegacyCredential] = [
        .init(key: "gmail_access_token", purpose: .gmailSignIn, kind: .accessToken),
        .init(key: "gmail_refresh_token", purpose: .gmailSignIn, kind: .refreshToken),
        .init(key: "gmail_token_expiry", purpose: .gmailSignIn, kind: .tokenExpiry),
        .init(key: "outlookAccessToken", purpose: .outlookSignIn, kind: .accessToken),
        .init(key: "outlookRefreshToken", purpose: .outlookSignIn, kind: .refreshToken),
        .init(key: "outlookTokenExpiry", purpose: .outlookSignIn, kind: .tokenExpiry),
        .init(key: "imap_password", purpose: .imapPassword, kind: .password),
        .init(key: "settings_imapPassword", purpose: .imapPassword, kind: .password),
        .init(key: "smtp_password", purpose: .smtpPassword, kind: .password),
        .init(key: "settings_smtpPassword", purpose: .smtpPassword, kind: .password),
    ]

    let reader: LegacyKeychainReading
    public init(reader: LegacyKeychainReading = SystemLegacyKeychain()) { self.reader = reader }

    /// The legacy items present now. Read failures are thrown, not hidden.
    public func unassigned() throws -> [LegacyCredential] {
        try Self.knownKeys.filter { try reader.read(key: $0.key).map { !$0.isEmpty } ?? false }
    }

    /// Copies the chosen legacy items into `account`'s own credential —
    /// only with a confirmation naming exactly that account and those keys.
    public func assign(_ items: [LegacyCredential], to account: MailAccount, confirmation: LegacyAssignmentConfirmation,
                       into credentials: CredentialStore, audience: String) throws {
        guard !items.isEmpty, confirmation.accountID == account.id, confirmation.keys == Set(items.map(\.key)) else {
            throw LegacyCredentialError.notConfirmed
        }
        for item in items where item.provider != account.provider { throw LegacyCredentialError.providerMismatch(key: item.key) }
        guard Set(items.map(\.purpose)).count == 1, let purpose = items.first?.purpose else { throw LegacyCredentialError.mixedPurposes }
        func value(_ kind: LegacyCredential.Kind) throws -> String? {
            guard let item = items.first(where: { $0.kind == kind }) else { return nil }
            guard let data = try reader.read(key: item.key) else { throw LegacyCredentialError.missing(key: item.key) }
            guard let text = String(data: data, encoding: .utf8) else { throw LegacyCredentialError.unreadable(key: item.key) }
            return text
        }
        switch purpose {
        case .imapPassword, .smtpPassword:
            guard let password = try value(.password) else { throw LegacyCredentialError.notConfirmed }
            try credentials.write(Data(password.utf8), kind: .password, account: account.id)
        case .gmailSignIn, .outlookSignIn:
            let access = try value(.accessToken) ?? ""
            let refresh = try value(.refreshToken)
            guard !access.isEmpty || !(refresh ?? "").isEmpty else { throw LegacyCredentialError.notConfirmed }
            // The old expiry was a timeInterval string; unknown → already expired (refresh first).
            let expiry = try value(.tokenExpiry).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            let set = OAuthTokenSet(accountID: account.id, issuer: account.issuer, audience: audience,
                                    accessToken: access, refreshToken: refresh, expiresAt: expiry, scopes: account.grantedScopes)
            try credentials.write(try set.encoded(), kind: .oauthTokenSet, account: account.id)
        }
    }

    /// Removes legacy items — a separate, explicit step after assignment.
    public func retire(_ items: [LegacyCredential]) throws {
        for item in items { try reader.delete(key: item.key) }
    }
}
