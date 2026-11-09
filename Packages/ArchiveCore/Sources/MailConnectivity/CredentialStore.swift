//
//  CredentialStore.swift
//  MailConnectivity
//
//  Plan v4 V4-02 (§3 A09, §7 Secrets): account-scoped secrets.
//
//  Every secret is keyed by the account's UUID and a kind — never by a user
//  name, a host or a provider-global key — so two accounts at the same
//  provider, or two IMAP servers with the same login, can never read each
//  other's secret. Writes are update-then-add (never delete-then-add: a
//  failed add after a delete would erase the last working secret), and every
//  OSStatus that is not success is thrown. Secrets live only in the Keychain:
//  never in UserDefaults, the archive database, backups, exports or
//  diagnostics.
//

import Foundation
import Security

public enum CredentialKind: String, Sendable, CaseIterable, Codable {
    /// JSON-encoded `OAuthTokenSet` (access + refresh token, expiry, scopes, audience).
    case oauthTokenSet = "oauth-token-set"
    /// An IMAP/SMTP password or app password.
    case password
}

public enum CredentialStoreError: LocalizedError, Equatable {
    case keychain(operation: String, status: OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return "The account's sign-in details could not be \(operation) in the Keychain: \(message) (\(status))."
        case .unexpectedData:
            return "The Keychain returned data in an unexpected form."
        }
    }
}

public protocol CredentialStore: Sendable {
    /// nil = no secret stored for this account and kind. Any other failure throws.
    func read(_ kind: CredentialKind, account: UUID) throws -> Data?
    /// Replaces the secret atomically; on failure the previous secret is untouched.
    func write(_ secret: Data, kind: CredentialKind, account: UUID) throws
    /// Removing a secret that does not exist is not an error.
    func delete(_ kind: CredentialKind, account: UUID) throws
}

// MARK: - Keychain

/// The four SecItem calls, injectable so the OSStatus handling is testable.
public protocol KeychainAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychain: KeychainAPI {
    public init() {}
    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    public func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    public func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }
    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

public struct KeychainCredentialStore: CredentialStore {
    /// Distinct from the legacy global service (`com.ecosanskriti.mailin`),
    /// so an account-scoped item can never be confused with an old global key.
    public static let service = "com.ecosanskriti.mailin.connected-account"

    let api: KeychainAPI
    let useDataProtectionKeychain: Bool

    /// `useDataProtectionKeychain` needs a signed app with a keychain access
    /// group; the app passes true. Unsigned test hosts pass false.
    public init(api: KeychainAPI = SystemKeychain(), useDataProtectionKeychain: Bool = true) {
        self.api = api
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    /// The Keychain account attribute: `<UUID>/<kind>`. Never a user name.
    public static func itemAccount(_ account: UUID, _ kind: CredentialKind) -> String {
        "\(account.uuidString)/\(kind.rawValue)"
    }

    func query(_ kind: CredentialKind, account: UUID) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.itemAccount(account, kind),
            // Never synchronised: a restored or second device must reauthorise (§7).
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func read(_ kind: CredentialKind, account: UUID) throws -> Data? {
        var q = query(kind, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = api.copyMatching(q)
        switch status {
        case errSecSuccess:
            guard let data else { throw CredentialStoreError.unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(operation: "read", status: status)
        }
    }

    public func write(_ secret: Data, kind: CredentialKind, account: UUID) throws {
        let q = query(kind, account: account)
        // 1. Update in place: atomic, and a failure leaves the old secret.
        let updated = api.update(q, [kSecValueData as String: secret])
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw CredentialStoreError.keychain(operation: "saved", status: updated)
        }
        // 2. No item yet: add one, device-only, readable after first unlock
        //    (background capture runs while the device is locked).
        var add = q
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = api.add(add)
        switch added {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Another writer added it in between: update that item.
            let retried = api.update(q, [kSecValueData as String: secret])
            guard retried == errSecSuccess else { throw CredentialStoreError.keychain(operation: "saved", status: retried) }
        default:
            throw CredentialStoreError.keychain(operation: "saved", status: added)
        }
    }

    public func delete(_ kind: CredentialKind, account: UUID) throws {
        let status = api.delete(query(kind, account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(operation: "removed", status: status)
        }
    }
}
