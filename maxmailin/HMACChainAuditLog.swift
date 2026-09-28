@testable import ArchiveCore
//
//  HMACChainAuditLog.swift
//  mailin
//
//  Tamper-evident audit log. Each entry's HMAC includes the HMAC of the
//  previous entry, forming a chain. Any modification inside the chain breaks
//  it at verify time — detectable and reportable.
//
//  Audit F11 (2026-09-28): a chain alone cannot detect TRUNCATION — every
//  prefix of a valid chain is itself valid, and an empty list verifies. The
//  log therefore also keeps an ANCHOR outside the log file: the count and
//  HMAC of the newest entry, in the Keychain next to the key. Verification
//  requires the file to end exactly at the anchor; a shorter, replaced or
//  missing log is reported as broken, not as a fresh log. A log file that
//  cannot be decoded is quarantined (never overwritten) and the next chain
//  begins with an entry that records the loss.
//
//  Key and anchor are per-install, stored in the Keychain. All on-device.
//  What this does NOT defend against: an administrator of this Mac who can
//  edit the Keychain as well as the file. A signed external anchor is the
//  3.1 follow-up.
//

import Foundation
import CryptoKit
import Security
import os.log

/// The newest entry's position and HMAC, kept outside the log file.
struct ChainHead: Codable, Equatable {
    var count: Int
    var hmac: String
}

/// Where the key and the anchor live. Production uses the Keychain; tests
/// use memory so they never touch the login keychain.
struct ChainAnchors {
    var loadKey: () throws -> SymmetricKey?
    var saveKey: (SymmetricKey) throws -> Void
    var loadHead: () -> ChainHead?
    var saveHead: (ChainHead?) -> Void

    static func keychain(tag: String) -> ChainAnchors {
        ChainAnchors(
            loadKey: { try KeychainItem.load(account: tag).map { SymmetricKey(data: $0) } },
            saveKey: { key in try KeychainItem.save(account: tag, data: key.withUnsafeBytes { Data($0) }) },
            loadHead: {
                guard let data = try? KeychainItem.load(account: tag + ".head") else { return nil }
                return try? JSONDecoder().decode(ChainHead.self, from: data)
            },
            saveHead: { head in
                if let head, let data = try? JSONEncoder().encode(head) {
                    try? KeychainItem.save(account: tag + ".head", data: data)
                } else {
                    KeychainItem.delete(account: tag + ".head")
                }
            })
    }

    static func inMemory() -> ChainAnchors {
        final class Box: @unchecked Sendable { var key: SymmetricKey?; var head: ChainHead? }
        let box = Box()
        return ChainAnchors(loadKey: { box.key }, saveKey: { box.key = $0 },
                            loadHead: { box.head }, saveHead: { box.head = $0 })
    }

    enum KeychainItem {
        static func load(account: String) throws -> Data? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw MaxmailinError.privacy(.keychainFailed, detail: "Keychain load status \(status) for \(account)")
            }
            return data
        }

        static func save(account: String, data: Data) throws {
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data
            ]
            SecItemDelete(attributes as CFDictionary)
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw MaxmailinError.privacy(.keychainFailed, detail: "Keychain save status \(status) for \(account)")
            }
        }

        static func delete(account: String) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
        }
    }
}

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

    /// The action name of the entry that opens a chain after the previous
    /// log was lost or unreadable. Its detail says what was lost.
    static let historyUnavailableAction = "audit.history.unavailable"

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "HMACChainAudit")
    private static let productionKeychainTag = "com.ecosanskriti.mailin.hmac-chain.v1"
    let storeURL: URL
    private let anchors: ChainAnchors

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var integrityState: IntegrityState = .unknown
    /// Set when the log on disk was missing or unreadable while an anchor
    /// said entries existed. The next `append` writes it into the new chain.
    private(set) var pendingLossNote: String?

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
        self.anchors = .keychain(tag: Self.productionKeychainTag)
        loadFromDisk()
    }

    /// Isolated log for tests: its own file and in-memory key and anchor.
    init(storeURL: URL, anchors: ChainAnchors) {
        self.storeURL = storeURL
        self.anchors = anchors
        loadFromDisk()
    }

    // MARK: - Append

    /// Append a new entry to the chain. Returns the entry's HMAC for callers
    /// that want to reference it (e.g. cross-reference with an export).
    @discardableResult
    func append(action: String, detail: String) throws -> Entry {
        // A chain that starts after a loss records the loss first, so the
        // gap is inside the evidence rather than only in a log message.
        if entries.isEmpty, let note = pendingLossNote {
            pendingLossNote = nil
            _ = try appendEntry(action: Self.historyUnavailableAction, detail: note)
        }
        return try appendEntry(action: action, detail: detail)
    }

    private func appendEntry(action: String, detail: String) throws -> Entry {
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
        // The anchor moves only after the file holds the entry.
        anchors.saveHead(ChainHead(count: entries.count, hmac: macHex))
        return entry
    }

    // MARK: - Verify

    /// Walk the entire chain and re-compute each HMAC, then require the chain
    /// to end exactly at the recorded anchor. Sets integrityState. Returns
    /// true if intact, false if broken — including broken by truncation, a
    /// replaced log, or a log that is missing while an anchor exists.
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

            // F11: the chain must END where the anchor says it ends.
            if let head = anchors.loadHead() {
                guard head.count == entries.count, head.hmac == entries.last?.hmac else {
                    let reason: String
                    if entries.count < head.count {
                        reason = "recorded head is entry \(head.count) (\(head.hmac.prefix(12))…); only \(entries.count) present — entries were removed or the log was replaced"
                    } else if entries.count == head.count {
                        reason = "the last entry does not match the recorded head — the log was replaced"
                    } else {
                        reason = "\(entries.count) entries present but the recorded head is entry \(head.count) — entries were added outside this app"
                    }
                    integrityState = .broken(atIndex: min(entries.count, head.count), reason: reason)
                    return false
                }
            } else if !entries.isEmpty {
                // First verification after the anchor was introduced: adopt
                // the chain as found. From here on, truncation is detectable.
                anchors.saveHead(ChainHead(count: entries.count, hmac: entries.last!.hmac))
            }
            if let note = pendingLossNote {
                integrityState = .broken(atIndex: -1, reason: note)
                return false
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

    /// Re-read the log file (tests, and after an external restore).
    func reloadFromDisk() {
        entries = []
        pendingLossNote = nil
        integrityState = .unknown
        loadFromDisk()
    }

    private func loadFromDisk() {
        let head = anchors.loadHead()
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            if let head {
                pendingLossNote = "audit log file missing; the recorded head was entry \(head.count) (\(head.hmac.prefix(12))…)"
                integrityState = .broken(atIndex: -1, reason: pendingLossNote!)
                logger.error("HMAC audit log missing while an anchor exists (\(head.count) entries recorded)")
            }
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            // Never overwrite an unreadable log: move it aside under a dated
            // name and start the next chain with an entry that says so.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = storeURL.deletingLastPathComponent()
                .appendingPathComponent("hmac_audit_chain.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: storeURL, to: quarantine)
            entries = []
            var note = "audit log unreadable (\(error.localizedDescription)); quarantined as \(quarantine.lastPathComponent)"
            if let head { note += "; the recorded head was entry \(head.count) (\(head.hmac.prefix(12))…)" }
            pendingLossNote = note
            integrityState = .broken(atIndex: -1, reason: note)
            logger.error("Failed to load HMAC audit log: \(error.localizedDescription, privacy: .public); quarantined")
        }
    }

    // MARK: - Key management

    private func fetchOrCreateKey() throws -> SymmetricKey {
        if let existing = try anchors.loadKey() {
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try anchors.saveKey(fresh)
        return fresh
    }
}
