//
//  HMACChainAuditLog.swift
//  maxmailin
//
//  Tamper-evident audit log. Each entry's HMAC includes the HMAC of the
//  previous entry, forming a chain. Any deletion or modification breaks
//  the chain at verify time — detectable and reportable.
//
//  Key is per-install, stored in Keychain. Compatible with the existing
//  ForensicManager (this is a parallel, stronger log). Future revisions
//  could replace the existing audit log entirely.
//
//  All on-device. No remote logging.
//

import Foundation
import CryptoKit
import Security
import os.log

@MainActor
final class HMACChainAuditLog: ObservableObject {

    static let shared = HMACChainAuditLog()

    struct Entry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let action: String
        let detail: String
        let previousHMAC: String?    // hex of the previous entry's HMAC; nil for genesis
        let hmac: String              // hex of this entry's HMAC

        var isGenesis: Bool { previousHMAC == nil }
    }

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "HMACChainAudit")
    private let keychainTag = "com.ecosanskriti.mailin.hmac-chain.v1"
    private let storeURL: URL

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var integrityState: IntegrityState = .unknown

    enum IntegrityState: Equatable {
        case unknown
        case verified(entryCount: Int)
        case broken(atIndex: Int, reason: String)
    }

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent(
            "com.ecosanskriti.mailin", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // W3: the audit chain is appended by background work (launch tasks,
        // import completion) — background-readable class; 700 dir on macOS.
        ArtifactProtection.applyBackgroundReadable(to: dir)
        self.storeURL = dir.appendingPathComponent("hmac_audit_chain.json")
        loadFromDisk()
    }

    // MARK: - Append

    /// Append a new entry to the chain. Returns the entry's HMAC for callers
    /// that want to reference it (e.g. cross-reference with an export).
    @discardableResult
    func append(action: String, detail: String) throws -> Entry {
        let key = try fetchOrCreateKey()
        let prev = entries.last?.hmac
        let id = UUID()
        let timestamp = Date()

        let body = "\(id.uuidString)|\(timestamp.timeIntervalSince1970)|\(action)|\(detail)|\(prev ?? "")"
        let bodyData = Data(body.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
        let macHex = Data(mac).map { String(format: "%02x", $0) }.joined()

        let entry = Entry(
            id: id,
            timestamp: timestamp,
            action: action,
            detail: detail,
            previousHMAC: prev,
            hmac: macHex
        )
        entries.append(entry)
        try saveToDisk()
        return entry
    }

    // MARK: - Verify

    /// Walk the entire chain and re-compute each HMAC. Sets integrityState.
    /// Returns true if intact, false if broken.
    @discardableResult
    func verifyChain() -> Bool {
        do {
            let key = try fetchOrCreateKey()
            var lastHMAC: String? = nil
            for (idx, entry) in entries.enumerated() {
                guard entry.previousHMAC == lastHMAC else {
                    integrityState = .broken(atIndex: idx, reason: "previousHMAC mismatch")
                    return false
                }
                let body = "\(entry.id.uuidString)|\(entry.timestamp.timeIntervalSince1970)|\(entry.action)|\(entry.detail)|\(entry.previousHMAC ?? "")"
                let bodyData = Data(body.utf8)
                let mac = HMAC<SHA256>.authenticationCode(for: bodyData, using: key)
                let recomputed = Data(mac).map { String(format: "%02x", $0) }.joined()
                guard recomputed == entry.hmac else {
                    integrityState = .broken(atIndex: idx, reason: "HMAC recompute mismatch")
                    return false
                }
                lastHMAC = entry.hmac
            }
            integrityState = .verified(entryCount: entries.count)
            return true
        } catch {
            integrityState = .broken(atIndex: -1, reason: "key load failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Persistence

    private func saveToDisk() throws {
        try PrivacyHardening.writeJSON(entries, to: storeURL)
        // W3: owner-only file; background-readable protection class on iOS.
        ArtifactProtection.applyBackgroundReadable(to: storeURL)
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            logger.error("Failed to load HMAC audit log: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Key management

    private func fetchOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKeyFromKeychain() {
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try storeKeyInKeychain(fresh)
        return fresh
    }

    private func loadKeyFromKeychain() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MaxmailinError.privacy(.keychainFailed,
                                         detail: "HMAC key load status \(status)")
        }
        return SymmetricKey(data: data)
    }

    private func storeKeyInKeychain(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemDelete(attributes as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MaxmailinError.privacy(.keychainFailed,
                                         detail: "HMAC key save status \(status)")
        }
    }
}
