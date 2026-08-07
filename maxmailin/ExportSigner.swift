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

@MainActor
final class ExportSigner {

    static let shared = ExportSigner()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "ExportSigner")

    private let keychainTag = "com.ecosanskriti.mailin.export-signer.v1"

    private var cachedPrivateKey: Curve25519.Signing.PrivateKey?

    private init() {}

    // MARK: - Key management

    /// Load (or generate on first use) the per-install signing key.
    func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let cachedPrivateKey { return cachedPrivateKey }

        if let stored = try loadFromKeychain() {
            cachedPrivateKey = stored
            return stored
        }

        let fresh = Curve25519.Signing.PrivateKey()
        try saveToKeychain(fresh)
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
        try PrivacyHardening.write(signature, to: sigURL)
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
        try PrivacyHardening.write(signature, to: sigURL)
        let digestURL = url.appendingPathExtension("sha256")
        try PrivacyHardening.write(Data(hex.utf8), to: digestURL)
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
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
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

    // MARK: - Keychain

    private func loadFromKeychain() throws -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
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
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func saveToKeychain(_ key: Curve25519.Signing.PrivateKey) throws {
        let data = key.rawRepresentation
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        // Remove any stale entry first.
        SecItemDelete(attributes as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MaxmailinError.privacy(.keychainFailed,
                                         detail: "SecItemAdd status \(status)")
        }
    }
}
