//
//  ExportSigner.swift
//  maxmailin
//
//  Ed25519 signing for export artifacts. Every export (PDF, CSV, JSON, EML
//  batch) gets a companion `.sig` file. Recipients can verify with the
//  bundled public key that the export hasn't been tampered with.
//
//  Key management strategy (v1):
//   • Per-install signing key generated on first use and stored in Keychain
//     with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. The public key
//     is also exposed so it can be embedded in reports.
//   • Future v2: per-export ephemeral keys with App Attest binding (Apple's
//     App Attest service confirms the signing happened on a real device).
//
//  Strict on-device: nothing leaves the device. No third-party signing.
//

import Foundation
import CryptoKit
import Security
import os.log

/// Where the signing key's raw bytes live (the Keychain in the app; a fake in tests).
protocol ExportSigningKeyStore {
    /// The stored bytes, or nil when no key has been stored yet.
    func load() throws -> Data?
    /// Stores the bytes of a NEW key. Only called when `load()` returned nil.
    func save(_ data: Data) throws
}

/// Review 2026-11-16 E: a stored key that cannot be read is reported, never
/// silently replaced — a new key would leave every earlier `.sig` unverifiable
/// with the published public key.
enum ExportSignerError: LocalizedError, Equatable {
    case storedKeyUnreadable(byteCount: Int)

    var errorDescription: String? {
        switch self {
        case .storedKeyUnreadable(let n):
            return "The export-signing key stored on this device (\(n) bytes) could not be read, so nothing was signed. "
                + "mailin did not replace it: a new key would make every earlier signature unverifiable with the published public key. "
                + "Restore the key from a Keychain backup, or remove the Keychain item \"\(ExportSigner.keychainTag)\" to start a new key on purpose."
        }
    }
}

@MainActor
final class ExportSigner {

    static let shared = ExportSigner()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "ExportSigner")

    nonisolated static let keychainTag = "com.ecosanskriti.mailin.export-signer.v1"

    private let keyStore: ExportSigningKeyStore
    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?

    private init() { keyStore = KeychainSigningKeyStore(account: Self.keychainTag) }

    /// Tests: a signer over an injected key store.
    init(keyStore: ExportSigningKeyStore) { self.keyStore = keyStore }

    // MARK: - Key management

    /// Load (or generate on first use) the per-install signing key. A stored
    /// key that does not parse throws `ExportSignerError.storedKeyUnreadable`
    /// and is left exactly as it is.
    func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let cachedPrivateKey { return cachedPrivateKey }

        if let stored = try keyStore.load() {
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
                cachedPrivateKey = key
                return key
            } catch {
                logger.error("stored export-signer key (\(stored.count) bytes) does not parse; it is not replaced")
                throw ExportSignerError.storedKeyUnreadable(byteCount: stored.count)
            }
        }

        let fresh = Curve25519.Signing.PrivateKey()
        try keyStore.save(fresh.rawRepresentation)
        cachedPrivateKey = fresh
        logger.info("Generated new export-signer key (Ed25519).")
        return fresh
    }

    /// Public key bytes — distribute alongside exports so recipients can verify.
    func publicKeyBytes() throws -> Data {
        try privateKey().publicKey.rawRepresentation
    }

    /// Public key as hex — convenient for inclusion in PDF report footers.
    func publicKeyHex() throws -> String {
        try publicKeyBytes().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Signing

    /// Atomic write with the strongest available file-protection class (the
    /// same rule as the app's `PrivacyHardening.write`; on macOS the
    /// protection class is a harmless no-op under FileVault).
    /// A signature / digest is public, so file protection is defence in depth
    /// only: when the system refuses the protected write (seen on macOS with a
    /// re-signed host, 2026-10-12: "no permission to save load.dat.sig" while
    /// the export beside it was written), it is written plainly rather than
    /// failing the whole signed export.
    private func protectedWrite(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            logger.notice("protected write refused for \(url.lastPathComponent, privacy: .public); writing without file protection")
            try data.write(to: url, options: .atomic)
        }
    }

    /// Sign arbitrary bytes. Returns 64-byte Ed25519 signature.
    func sign(_ data: Data) throws -> Data {
        let key = try privateKey()
        return try key.signature(for: data)
    }

    /// Sign a file and write the companion `.sig` file next to it.
    @discardableResult
    func signFile(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        let signature = try sign(data)
        let sigURL = url.appendingPathExtension("sig")
        try protectedWrite(signature, to: sigURL)
        logger.info("Signed export: \(url.lastPathComponent) → \(sigURL.lastPathComponent)")
        return sigURL
    }

    /// Part O: sign a STREAMED export. Large exports are written incrementally
    /// and their SHA-256 is computed while writing — the finished artifact is
    /// never re-read into memory. The Ed25519 signature covers the 32-byte
    /// digest; a `.sha256` sidecar records the digest hex so recipients can
    /// verify independently (recompute streaming SHA-256, check signature over
    /// the digest bytes).
    @discardableResult
    func signStreamedDigest(_ digest: Data, hex: String, for url: URL) throws -> URL {
        let signature = try sign(digest)
        let sigURL = url.appendingPathExtension("sig")
        try protectedWrite(signature, to: sigURL)
        let digestURL = url.appendingPathExtension("sha256")
        try protectedWrite(Data(hex.utf8), to: digestURL)
        logger.info("Signed streamed export: \(url.lastPathComponent) → \(sigURL.lastPathComponent) (digest-based)")
        return sigURL
    }

    /// Verify a streamed-export signature: recompute the file's SHA-256 in
    /// bounded chunks (never loading the whole file) and check the Ed25519
    /// signature over the digest bytes.
    func verifyStreamedFile(_ url: URL, signature: Data, publicKey: Data) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try? autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return verify(Data(digest.finalize()), signature: signature, publicKey: publicKey)
    }

    /// Verify a signature against arbitrary bytes. Used by the diagnostic
    /// "Verify export" flow.
    func verify(_ data: Data, signature: Data, publicKey: Data) -> Bool {
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return pk.isValidSignature(signature, for: data)
    }
}

// MARK: - Keychain

struct KeychainSigningKeyStore: ExportSigningKeyStore {
    let account: String

    func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound { return nil }
            throw MaxmailinError.privacy(.keychainFailed,
                                         detail: "SecItemCopyMatching status \(status)")
        }
        return data
    }

    /// Reached only when `load()` found no item; an existing item is never deleted here.
    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MaxmailinError.privacy(.keychainFailed,
                                         detail: "SecItemAdd status \(status)")
        }
    }
}
