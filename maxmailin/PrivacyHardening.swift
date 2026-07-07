//
//  PrivacyHardening.swift
//  maxmailin
//
//  Utilities for strict on-device privacy:
//   • Atomic write with iOS Data Protection "complete" class so files become
//     literally unreadable when the device is locked.
//   • Explicit zeroing of sensitive Data buffers after use (best-effort: ARC
//     can't guarantee no copies but we minimize the obvious lifetime).
//   • SecureRandom helper that uses CryptoKit's drbg.
//
//  Pure Apple frameworks. No third-party.
//

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

enum PrivacyHardening {

    /// Atomic write with the strongest available file-protection class.
    /// On iOS this means the file is encrypted with a key derived from the
    /// user's passcode; it's unreadable while the device is locked.
    /// On macOS, NSFileProtectionComplete is a no-op (filesystem encryption
    /// is handled at the volume level by FileVault), but passing it is
    /// harmless.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Best-effort zeroing of a mutable Data buffer. Use right after consuming
    /// sensitive material (private keys, decrypted bodies, raw hashes that
    /// should not linger in memory).
    static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                memset_s(baseAddress, ptr.count, 0, ptr.count)
            }
        }
        data.removeAll(keepingCapacity: false)
    }

    /// Cryptographically secure random bytes via CryptoKit's CSPRNG.
    static func secureRandomBytes(count: Int) -> Data {
        var key = SymmetricKey(size: SymmetricKeySize(bitCount: count * 8))
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Lightweight wrapper to write the bytes of a `Codable` value to disk with
/// privacy hardening. Convenience used by the new v2 storage and forensic
/// modules.
extension PrivacyHardening {
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try write(data, to: url)
    }
}
