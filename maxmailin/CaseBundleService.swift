import Foundation
import CryptoKit
import os.log

// MARK: - Sealed Case Bundles (V3-E3)
//
// A `.mailincase` bundle is the team-handoff unit: one JSON file carrying a
// case's emails (raw RFC-822 sources), the studio artifacts (ACH matrices,
// fact–evidence matrices, action registers, evidence desks, reasoning cases),
// and provenance — sealed with a SHA-256 digest + Ed25519 signature.
//
// Enterprise rules:
// - Import VERIFIES THE SEAL FIRST. A tampered bundle is refused with the
//   exact failure (content mismatch / bad signature), never partially opened.
// - The seal travels with its public key, so any machine can verify a bundle
//   without contacting the exporting machine (local-first, no server).
// - Import never overwrites: incoming artifacts are added alongside local
//   ones, labelled with the exporting examiner (E4 merge attribution).

struct CaseBundle: Codable {
    var formatVersion: Int = 1
    var caseTitle: String
    var exportedBy: String
    var orgName: String?
    var exportedAt: Date
    var note: String = ""

    /// Raw emails (RFC-822 source) so the receiving machine can re-import
    /// with full fidelity and recompute hashes independently.
    struct BundledEmail: Codable {
        var messageID: String?
        var subject: String
        var rawSource: String
        var sha256Hex: String
    }
    var emails: [BundledEmail] = []

    // Studio artifacts travel as their canonical models.
    var achMatrices: [ACHMatrixModel] = []
    var factMatrices: [FactEvidenceModel] = []
    var actionRegisters: [ActionRegisterModel] = []
    var evidenceDesks: [EvidenceDeskModel] = []
    var reasoningCases: [ReasoningCaseModel] = []
}

/// The on-disk envelope: payload + detached seal over the exact payload bytes.
struct CaseBundleEnvelope: Codable {
    var payloadBase64: String
    var receipt: SealedReceipt
}

@MainActor
enum CaseBundleService {

    static let fileExtension = "mailincase"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "CaseBundle")

    enum BundleError: LocalizedError {
        case sealFailed(String)
        case notABundle
        case sealBroken(SealedReceipt.VerifyResult)

        var errorDescription: String? {
            switch self {
            case .sealFailed(let detail):
                return "Could not seal the case bundle: \(detail)"
            case .notABundle:
                return "This file is not a valid .mailincase bundle."
            case .sealBroken(let result):
                switch result {
                case .contentMismatch(let expected, let actual):
                    return "REFUSED: the bundle was modified after sealing. Sealed digest \(expected.prefix(12))…, actual \(actual.prefix(12))…"
                case .badSignature:
                    return "REFUSED: the bundle's signature does not verify — the seal is not authentic."
                case .malformed:
                    return "REFUSED: the bundle's seal is malformed."
                case .valid:
                    return "Unexpected."
                }
            }
        }
    }

    // MARK: Export

    /// Builds a sealed bundle from a set of emails + all current studio
    /// artifacts (callers can pass filtered artifact lists for a narrower case).
    static func export(
        caseTitle: String,
        emails: [MBOXParser.RawEmail],
        note: String = "",
        achMatrices: [ACHMatrixModel]? = nil,
        factMatrices: [FactEvidenceModel]? = nil,
        actionRegisters: [ActionRegisterModel]? = nil,
        evidenceDesks: [EvidenceDeskModel]? = nil,
        reasoningCases: [ReasoningCaseModel]? = nil,
        to url: URL
    ) throws {
        var bundle = CaseBundle(
            caseTitle: caseTitle,
            exportedBy: ManagedConfig.examinerName ?? ForensicManager.shared.examinerName,
            orgName: ManagedConfig.orgName,
            exportedAt: Date(),
            note: note
        )
        bundle.emails = emails.map { email in
            let digest = SHA256.hash(data: Data(email.rawSource.utf8))
            return CaseBundle.BundledEmail(
                messageID: email.headers["Message-ID"] ?? email.headers["Message-Id"],
                subject: email.headers["Subject"] ?? "",
                rawSource: email.rawSource,
                sha256Hex: digest.map { String(format: "%02x", $0) }.joined()
            )
        }
        bundle.achMatrices = achMatrices ?? ACHMatrixStore.shared.matrices
        bundle.factMatrices = factMatrices ?? FactEvidenceStore.shared.matrices
        bundle.actionRegisters = actionRegisters ?? ActionRegisterStore.shared.registers
        bundle.evidenceDesks = evidenceDesks ?? EvidenceDeskStore.shared.desks
        bundle.reasoningCases = reasoningCases ?? ReasoningCaseStore.shared.cases

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let payload = try enc.encode(bundle)

        let receipt: SealedReceipt
        do {
            receipt = try ReceiptSealer.seal(content: payload, sealedBy: bundle.exportedBy)
        } catch {
            throw BundleError.sealFailed(error.localizedDescription)
        }

        let envelope = CaseBundleEnvelope(payloadBase64: payload.base64EncodedString(), receipt: receipt)
        let envelopeEnc = JSONEncoder()
        envelopeEnc.outputFormatting = [.prettyPrinted, .sortedKeys]
        envelopeEnc.dateEncodingStrategy = .iso8601
        try envelopeEnc.encode(envelope).write(to: url, options: .atomic)

        ForensicManager.shared.logAction(
            "Case bundle exported",
            detail: "\(caseTitle): \(bundle.emails.count) emails, sealed \(receipt.sha256Hex.prefix(12))…")
    }

    // MARK: Verify + open

    /// Verifies the seal and returns the bundle. A broken seal throws —
    /// the payload is never handed to the caller.
    static func open(url: URL) throws -> (bundle: CaseBundle, receipt: SealedReceipt) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let envelope = try? dec.decode(CaseBundleEnvelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payloadBase64) else {
            throw BundleError.notABundle
        }
        let result = ReceiptSealer.verify(content: payload, receipt: envelope.receipt)
        guard result == .valid else {
            log.error("Refused case bundle \(url.lastPathComponent): seal verification failed")
            throw BundleError.sealBroken(result)
        }
        let bundle = try dec.decode(CaseBundle.self, from: payload)
        return (bundle, envelope.receipt)
    }

    // MARK: Import (E4 — attributed, additive merge)

    struct MergeReport {
        var artifactsAdded = 0
        var conflictsLabelled = 0
        var emailsInBundle = 0
        var from = ""
    }

    /// Merges a verified bundle's studio artifacts into the local stores.
    /// NEVER overwrites: an incoming artifact whose id already exists locally
    /// with DIFFERENT content is added as a copy labelled with the sender —
    /// both readings stand (conflicts surfaced, not silently merged).
    /// Identical artifacts (same id + content) are skipped.
    @discardableResult
    static func mergeArtifacts(from bundle: CaseBundle) -> MergeReport {
        var report = MergeReport()
        report.emailsInBundle = bundle.emails.count
        report.from = bundle.exportedBy.isEmpty ? "unknown examiner" : bundle.exportedBy
        let senderLabel = report.from

        func mergeList<T: Identifiable & Equatable>(
            _ incoming: [T],
            into local: inout [T],
            retitle: (inout T, String) -> Void
        ) where T.ID == UUID {
            for var item in incoming {
                if let existing = local.first(where: { $0.id == item.id }) {
                    if existing == item { continue }         // identical — skip
                    var relabelled = item                     // conflict — keep both
                    relabelled = item
                    retitle(&relabelled, senderLabel)
                    // Give the copy a fresh id so both versions persist.
                    relabelled = reassignID(relabelled)
                    local.insert(relabelled, at: 0)
                    report.conflictsLabelled += 1
                } else {
                    retitle(&item, senderLabel)
                    local.insert(item, at: 0)
                    report.artifactsAdded += 1
                }
            }
        }

        var ach = ACHMatrixStore.shared.matrices
        mergeList(bundle.achMatrices, into: &ach) { $0.title += " (from \($1))" }
        ACHMatrixStore.shared.matrices = ach

        var fact = FactEvidenceStore.shared.matrices
        mergeList(bundle.factMatrices, into: &fact) { $0.title += " (from \($1))" }
        FactEvidenceStore.shared.matrices = fact

        var regs = ActionRegisterStore.shared.registers
        mergeList(bundle.actionRegisters, into: &regs) { $0.title += " (from \($1))" }
        ActionRegisterStore.shared.registers = regs

        var desks = EvidenceDeskStore.shared.desks
        mergeList(bundle.evidenceDesks, into: &desks) { $0.title += " (from \($1))" }
        EvidenceDeskStore.shared.desks = desks

        var cases = ReasoningCaseStore.shared.cases
        mergeList(bundle.reasoningCases, into: &cases) { $0.title += " (from \($1))" }
        ReasoningCaseStore.shared.cases = cases

        ForensicManager.shared.logAction(
            "Case bundle merged",
            detail: "from \(senderLabel): \(report.artifactsAdded) added, \(report.conflictsLabelled) conflicts kept as labelled copies")
        return report
    }

    /// Fresh identity for a conflict copy so both versions persist side by side.
    private static func reassignID<T>(_ item: T) -> T {
        var copy = item
        switch copy {
        case var m as ACHMatrixModel:      m.id = UUID(); copy = m as! T
        case var m as FactEvidenceModel:   m.id = UUID(); copy = m as! T
        case var m as ActionRegisterModel: m.id = UUID(); copy = m as! T
        case var m as EvidenceDeskModel:   m.id = UUID(); copy = m as! T
        case var m as ReasoningCaseModel:  m.id = UUID(); copy = m as! T
        default: break
        }
        return copy
    }
}
