//
//  AIKeyProfileStore.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-02 (§13.4, B02): customer AI keys, in the Keychain only.
//
//   - One item per profile, found by `<profile UUID>/<provider>/<endpoint host>`
//     under its own service — never the connected-mail service, never the
//     legacy global service — so a mail credential can never be read as an AI
//     key, and a reference to another provider or host finds nothing.
//   - Add refuses to overwrite; replace updates in place (atomic: a failed
//     replace leaves the old working key); remove reports whether anything was
//     removed. Every OSStatus that is not success is thrown, with the
//     operation, for the screen to show.
//   - Never synchronised, this device only, readable only while unlocked: a
//     restored or second device starts disconnected and needs a new key.
//   - There is no default or embedded developer key: the store only ever
//     returns what the customer saved.
//
//  Settings for this are hidden until a runtime exists (`AIScaffoldRuntime`
//  in the app); nothing in the shipping journey calls `add` or `replace`.
//

import Foundation
import Security

/// The four SecItem calls, injectable so every OSStatus path is testable.
public protocol AISecretKeychain: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemAISecretKeychain: AISecretKeychain {
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

public enum AIKeyOperation: String, Sendable, Codable {
    case add, replace, remove, read
}

public enum AIKeyStoreError: Error, Sendable, Equatable {
    /// The Keychain refused: the status is shown, never swallowed.
    case keychain(operation: AIKeyOperation, status: OSStatus)
    /// `add` found a key already saved for this profile (use replace).
    case alreadyExists
    /// `replace` found no key to replace.
    case notFound
    case emptySecret
    case unexpectedData

    public var osStatus: OSStatus? {
        if case .keychain(_, let status) = self { return status }
        return nil
    }

    public var message: String {
        switch self {
        case .keychain(let operation, let status):
            let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            let verb: String
            switch operation {
            case .add: verb = "saved"
            case .replace: verb = "replaced"
            case .remove: verb = "removed"
            case .read: verb = "read"
            }
            return "The AI key could not be \(verb) in the Keychain: \(text) (\(status))."
        case .alreadyExists: return "A key is already saved for this profile."
        case .notFound: return "No key is saved for this profile."
        case .emptySecret: return "The key is empty."
        case .unexpectedData: return "The Keychain returned data in an unexpected form."
        }
    }
}

public struct AIKeyProfileStore: Sendable {
    /// Distinct from the connected-mail service (`…connected-account`) and the
    /// legacy global one (`com.ecosanskriti.mailin`).
    public static let service = "com.ecosanskriti.mailin.ai-provider-key"

    let keychain: any AISecretKeychain
    let useDataProtectionKeychain: Bool

    /// `useDataProtectionKeychain` needs a signed app with a keychain access
    /// group; the app passes true. Unsigned test hosts pass false.
    public init(keychain: any AISecretKeychain = SystemAISecretKeychain(), useDataProtectionKeychain: Bool = true) {
        self.keychain = keychain
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    func query(_ ref: AICredentialReference) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: ref.keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func read(_ ref: AICredentialReference) throws -> AISecret? {
        var q = query(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copyMatching(q)
        switch status {
        case errSecSuccess:
            guard let data, !data.isEmpty else { throw AIKeyStoreError.unexpectedData }
            return AISecret(data)
        case errSecItemNotFound:
            return nil
        default:
            throw AIKeyStoreError.keychain(operation: .read, status: status)
        }
    }

    public func hasKey(_ ref: AICredentialReference) throws -> Bool { try read(ref) != nil }

    /// Saves a key for a profile that has none. Never overwrites.
    public func add(_ secret: Data, for ref: AICredentialReference) throws {
        guard !secret.isEmpty else { throw AIKeyStoreError.emptySecret }
        var attributes = query(ref)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = keychain.add(attributes)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw AIKeyStoreError.alreadyExists
        default: throw AIKeyStoreError.keychain(operation: .add, status: status)
        }
    }

    /// Replaces the key in place. On any failure the old key is untouched
    /// (an update, never delete-then-add).
    public func replace(_ secret: Data, for ref: AICredentialReference) throws {
        guard !secret.isEmpty else { throw AIKeyStoreError.emptySecret }
        let status = keychain.update(query(ref), [kSecValueData as String: secret])
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw AIKeyStoreError.notFound
        default: throw AIKeyStoreError.keychain(operation: .replace, status: status)
        }
    }

    /// True when a key was removed, false when there was none.
    @discardableResult
    public func remove(_ ref: AICredentialReference) throws -> Bool {
        let status = keychain.delete(query(ref))
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw AIKeyStoreError.keychain(operation: .remove, status: status)
        }
    }
}
