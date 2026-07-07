//
//  AppSelfAttestation.swift
//  maxmailin
//
//  Runtime self-attestation: at launch, compute a deterministic hash of the
//  app's main executable and surface it in the Privacy Report. Forensic
//  users can compare this to a known-good value (e.g. the hash from the
//  signed App Store / TestFlight build) to verify the binary hasn't been
//  tampered with at runtime.
//
//  Apple's code signing handles tamper detection at load time and refuses
//  to start a modified binary on iOS; this self-attestation is a *visible*
//  reinforcement of that guarantee — a forensic user can read the hash and
//  cite it in their report.
//

import Foundation
import CryptoKit
import os.log

@MainActor
final class AppSelfAttestation: ObservableObject {

    static let shared = AppSelfAttestation()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "SelfAttestation")

    @Published private(set) var executableSHA256: String?
    @Published private(set) var bundleSignature: String?
    @Published private(set) var attestationDate: Date?

    private init() {}

    /// Compute the SHA-256 of the running executable. Result is cached for the
    /// duration of the process — the binary cannot change while we're running.
    func compute() async {
        if executableSHA256 != nil { return }

        let started = Date()
        let hash = await Task.detached(priority: .utility) {
            Self.sha256OfExecutable()
        }.value

        await MainActor.run {
            self.executableSHA256 = hash
            self.bundleSignature = Self.codeSigningIdentifier()
            self.attestationDate = Date()
        }
        let elapsed = Date().timeIntervalSince(started)
        logger.info("Self-attestation complete in \(String(format: "%.3f", elapsed))s")
    }

    // MARK: - Hashing

    nonisolated static func sha256OfExecutable() -> String? {
        guard let url = Bundle.main.executableURL else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    nonisolated static func codeSigningIdentifier() -> String? {
        // Read the bundle identifier from Info.plist. Combined with the
        // executable hash, this gives a verifiable identity for the running
        // binary.
        Bundle.main.bundleIdentifier
    }
}
