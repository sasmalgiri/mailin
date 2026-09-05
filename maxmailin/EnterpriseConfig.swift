import Foundation
import CryptoKit
import os.log

// MARK: - Managed App Configuration (V3-E1)
//
// Reads the MDM-pushed dictionary Apple defines for managed apps
// (`com.apple.configuration.managed` in UserDefaults). Every key is optional;
// unmanaged installs behave exactly as before. Org policies are HARD gates:
// a managed "cloud AI disabled" cannot be re-enabled from the UI.
//
// Key reference (documented in ENTERPRISE_DEPLOYMENT.md):
//   orgName            string  — shown in About/reports; marks a managed install
//   examinerName       string  — preset examiner identity for who-stamps
//   disableCloudAI     bool    — hard-off for all cloud AI (opt-in impossible)
//   requireBiometricLock bool  — forces app lock on; user cannot disable
//   caseNumberPrefix   string  — preset prefix for case/Bates numbering
//   licenseKey         string  — pilot enterprise licensing (E2 interim)

enum ManagedConfig {

    static let managedDefaultsKey = "com.apple.configuration.managed"

    private static var dict: [String: Any] {
        UserDefaults.standard.dictionary(forKey: managedDefaultsKey) ?? [:]
    }

    /// True when any MDM configuration is present.
    static var isManaged: Bool { !dict.isEmpty }

    static var orgName: String? {
        dict["orgName"] as? String
    }

    static var examinerName: String? {
        dict["examinerName"] as? String
    }

    /// HARD org gate: when true, cloud AI is off and cannot be enabled.
    static var disableCloudAI: Bool {
        dict["disableCloudAI"] as? Bool ?? false
    }

    /// HARD org gate: when true, the biometric/passcode lock is always on.
    static var requireBiometricLock: Bool {
        dict["requireBiometricLock"] as? Bool ?? false
    }

    static var caseNumberPrefix: String? {
        dict["caseNumberPrefix"] as? String
    }

    static var licenseKey: String? {
        dict["licenseKey"] as? String
    }

    /// One-line provenance string for reports and About.
    static var provenanceLine: String? {
        guard isManaged else { return nil }
        return "Managed deployment\(orgName.map { " — \($0)" } ?? "")"
    }
}

// MARK: - Sealed Receipts (V3 Phase 4 / E3 foundation)
//
// A sealed receipt makes a work product tamper-evident and third-party
// verifiable: SHA-256 digest of the exact content + Ed25519 signature over
// that digest (per-install key from ExportSigner, public key embedded so a
// recipient can verify without this machine).
//
// verify(...) recomputes the digest from the presented content and checks
// the signature — any edit to the content fails loudly.

struct SealedReceipt: Codable, Equatable {
    let sha256Hex: String
    let signatureBase64: String
    let publicKeyBase64: String
    let sealedAt: Date
    let sealedBy: String

    enum VerifyResult: Equatable {
        case valid
        case contentMismatch(expected: String, actual: String)
        case badSignature
        case malformed
    }
}

@MainActor
enum ReceiptSealer {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "ReceiptSealer")

    /// Seals the given content. `sealedBy` records the human examiner
    /// (managed examiner name wins when present — org identity is policy).
    static func seal(content: Data, sealedBy: String) throws -> SealedReceipt {
        let digest = SHA256.hash(data: content)
        let digestData = Data(digest)
        let signature = try ExportSigner.shared.sign(digestData)
        let publicKey = try ExportSigner.shared.publicKeyBytes()
        let examiner = ManagedConfig.examinerName ?? sealedBy
        return SealedReceipt(
            sha256Hex: digest.map { String(format: "%02x", $0) }.joined(),
            signatureBase64: signature.base64EncodedString(),
            publicKeyBase64: publicKey.base64EncodedString(),
            sealedAt: Date(),
            sealedBy: examiner
        )
    }

    static func seal(text: String, sealedBy: String) throws -> SealedReceipt {
        try seal(content: Data(text.utf8), sealedBy: sealedBy)
    }

    /// Verifies content against a receipt. Pure function — works on any
    /// machine given the receipt (public key travels inside it).
    static func verify(content: Data, receipt: SealedReceipt) -> SealedReceipt.VerifyResult {
        let digest = SHA256.hash(data: content)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHex == receipt.sha256Hex else {
            return .contentMismatch(expected: receipt.sha256Hex, actual: actualHex)
        }
        guard let signature = Data(base64Encoded: receipt.signatureBase64),
              let publicKey = Data(base64Encoded: receipt.publicKeyBase64) else {
            return .malformed
        }
        let ok = ExportSigner.shared.verify(Data(digest), signature: signature, publicKey: publicKey)
        return ok ? .valid : .badSignature
    }

    static func verify(text: String, receipt: SealedReceipt) -> SealedReceipt.VerifyResult {
        verify(content: Data(text.utf8), receipt: receipt)
    }
}

// MARK: - Prohibited Outcomes (V3 Phase 4)
//
// kalsmritikosh rule: every professional job declares what the tool must
// never assert. Surfaced in the workflow runner at sign-off time as a
// standing reminder — the record shows the examiner was warned.

enum ProhibitedOutcomes {

    /// Prohibited outcomes per workflow definition id. Additive lookup —
    /// unknown ids get the base rule.
    static func outcomes(for defID: String) -> [String] {
        var rules = [baseRule]
        switch defID {
        case let id where id.hasPrefix("builtin.forensic"):
            rules.append("Do not assert guilt, intent, or wrongdoing — findings describe evidence, people decide.")
        case let id where id.hasPrefix("builtin.legal"):
            rules.append("Do not treat outputs as legal advice or a privilege determination — counsel decides.")
        case let id where id.hasPrefix("builtin.journalist"):
            rules.append("Do not publish an uncited claim — every published statement must reopen to evidence.")
        case let id where id.hasPrefix("builtin.researcher"):
            rules.append("Do not present coded interpretations as source facts — codes cite passages, they don't replace them.")
        case let id where id.hasPrefix("builtin.it"):
            rules.append("Do not treat a detection as attribution — indicators suggest, humans attribute.")
        case let id where id.hasPrefix("builtin.personal"):
            rules.append("Deletions and shares are yours to confirm — the app never removes or sends on its own.")
        default:
            break
        }
        return rules
    }

    static let baseRule =
        "This tool records and organizes evidence; it does not make determinations. Absence of evidence is not evidence of absence."
}
