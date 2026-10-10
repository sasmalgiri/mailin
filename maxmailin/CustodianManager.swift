@testable import ArchiveCore
import Foundation
import SwiftUI
import CryptoKit
import os.log

private let custodianLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Custodian")

@MainActor
class CustodianManager: ObservableObject {
    static let shared = CustodianManager()

    // §3-F4: with `v3LegalState` on, every change is also mirrored into the
    // archive database (coalesced); the files are always written.
    @Published var custodians: [UUID: String] = [:] { didSet { if _initialized { saveCustodians(); mirror() } } }
    @Published var legalHolds: Set<UUID> = [] { didSet { if _initialized { saveLegalHolds(); mirror() } } }
    @Published var evidenceSeals: [UUID: String] = [:] { didSet { if _initialized { saveSeals(); mirror() } } }
    private var _initialized = false

    var defaultCustodian: String {
        let names = Set(custodians.values)
        return names.count == 1 ? (names.first ?? "") : ""
    }

    private static let appSupportDir: URL = {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let custodiansURL = appSupportDir.appendingPathComponent("custodians.json")
    private let legalHoldsURL = appSupportDir.appendingPathComponent("legal_holds.json")
    private let sealsURL = appSupportDir.appendingPathComponent("evidence_seals.json")

    private func mirror() {
        if LegalStateMirror.isEnabled { LegalStateMirror.shared.scheduleSync() }
    }

    /// One assignment per collection, so the files are written once and the
    /// database mirror gets one coalesced diff (v3 bulk path).
    private var batching: Bool { LegalStateMirror.isEnabled }

    /// Pulls rows written directly into the database by a whole-scope action
    /// (§3-F4) into memory and therefore into the files. `nil` = unchanged.
    func absorbFromDatabase(holds: Set<UUID>?, seals: [UUID: String]?, custodians newCustodians: [UUID: String]?) {
        if let holds, holds != legalHolds { legalHolds = holds }
        if let seals {
            // Seals are set once: never replace an existing value.
            let merged = evidenceSeals.merging(seals) { current, _ in current }
            if merged.count != evidenceSeals.count { evidenceSeals = merged }
        }
        if let newCustodians, newCustodians != custodians { custodians = newCustodians }
    }

    private init() {
        loadCustodians()
        loadLegalHolds()
        loadSeals()
        _initialized = true
    }

    private func saveCustodians() {
        do {
            let dict = custodians.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
            let data = try JSONEncoder().encode(dict)
            try data.write(to: custodiansURL, options: .atomic)
        } catch {
            custodianLog.error("Failed to save custodians: \(error.localizedDescription)")
        }
    }

    private func loadCustodians() {
        guard FileManager.default.fileExists(atPath: custodiansURL.path) else { return }
        do {
            let data = try Data(contentsOf: custodiansURL)
            let dict = try JSONDecoder().decode([String: String].self, from: data)
            var loaded: [UUID: String] = [:]
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    loaded[uuid] = value
                }
            }
            custodians = loaded
        } catch {
            custodianLog.error("Failed to decode custodians: \(error.localizedDescription)")
        }
    }

    private func saveLegalHolds() {
        do {
            let arr = legalHolds.map(\.uuidString)
            let data = try JSONEncoder().encode(arr)
            try data.write(to: legalHoldsURL, options: .atomic)
        } catch {
            custodianLog.error("Failed to save legal holds: \(error.localizedDescription)")
        }
    }

    private func loadLegalHolds() {
        guard FileManager.default.fileExists(atPath: legalHoldsURL.path) else { return }
        do {
            let data = try Data(contentsOf: legalHoldsURL)
            let arr = try JSONDecoder().decode([String].self, from: data)
            legalHolds = Set(arr.compactMap { UUID(uuidString: $0) })
        } catch {
            custodianLog.error("Failed to decode legal holds: \(error.localizedDescription)")
        }
    }

    func assignCustodian(_ name: String, to emailID: UUID) {
        custodians[emailID] = name
        ForensicManager.shared.logAction("Custodian Assigned", detail: "\(name) assigned to email \(emailID)")
    }

    func assignCustodian(_ name: String, to emailIDs: [UUID]) {
        if batching {
            var next = custodians
            for id in emailIDs { next[id] = name }
            custodians = next
        } else {
            for id in emailIDs {
                custodians[id] = name
            }
        }
        ForensicManager.shared.logAction("Custodian Assigned", detail: "\(name) assigned to \(emailIDs.count) emails")
    }

    func removeCustodian(from emailID: UUID) {
        custodians.removeValue(forKey: emailID)
    }

    func custodian(for emailID: UUID) -> String? {
        custodians[emailID]
    }

    var allCustodians: [String] {
        Array(Set(custodians.values)).sorted()
    }

    func emailIDs(for custodian: String) -> [UUID] {
        custodians.filter { $0.value == custodian }.map(\.key)
    }

    // MARK: - Legal Hold

    func placeLegalHold(_ emailID: UUID) {
        legalHolds.insert(emailID)
        ForensicManager.shared.logAction("Legal Hold Placed", detail: "Email \(emailID) placed under legal hold")
    }

    func placeLegalHold(_ emailID: UUID, email: MBOXParser.RawEmail) {
        legalHolds.insert(emailID)
        sealEvidence(email)
        ForensicManager.shared.logAction("Legal Hold Placed", detail: "Email \(emailID) placed under legal hold with evidence seal")
    }

    func removeLegalHold(_ emailID: UUID) {
        legalHolds.remove(emailID)
        evidenceSeals.removeValue(forKey: emailID)
        ForensicManager.shared.logAction("Legal Hold Removed", detail: "Legal hold removed from email \(emailID)")
    }

    func isUnderLegalHold(_ emailID: UUID) -> Bool {
        legalHolds.contains(emailID)
    }

    func placeLegalHold(on emailIDs: [UUID]) {
        if batching {
            legalHolds = legalHolds.union(emailIDs)
        } else {
            for id in emailIDs {
                legalHolds.insert(id)
            }
        }
        ForensicManager.shared.logAction("Legal Hold Placed", detail: "Legal hold placed on \(emailIDs.count) emails")
    }

    func placeLegalHold(on emails: [MBOXParser.RawEmail]) {
        if batching {
            holdAndSealBatched(emails)
        } else {
            for email in emails {
                legalHolds.insert(email.id)
                sealEvidence(email)
            }
        }
        ForensicManager.shared.logAction("Legal Hold Placed", detail: "Legal hold placed on \(emails.count) emails with evidence seals")
    }

    // MARK: - Bulk Legal Hold by Source

    func placeLegalHoldBySource(_ sourceFormat: String, emails: [MBOXParser.RawEmail]) {
        let matching = emails.filter { ($0.headers["X-Source-Format"] ?? "").lowercased() == sourceFormat.lowercased() ||
            $0.rawSource.lowercased().contains(sourceFormat.lowercased()) }
        if batching {
            holdAndSealBatched(matching)
        } else {
            for email in matching {
                legalHolds.insert(email.id)
                sealEvidence(email)
            }
        }
        ForensicManager.shared.logAction("Bulk Legal Hold by Source", detail: "Legal hold placed on \(matching.count) emails from source: \(sourceFormat)")
    }

    func placeLegalHoldOnAll(_ emails: [MBOXParser.RawEmail]) {
        if batching {
            holdAndSealBatched(emails)
        } else {
            for email in emails {
                legalHolds.insert(email.id)
                sealEvidence(email)
            }
        }
        ForensicManager.shared.logAction("Bulk Legal Hold All", detail: "Legal hold placed on all \(emails.count) emails with evidence seals")
    }

    // MARK: - Evidence Sealing

    func sealEvidence(_ email: MBOXParser.RawEmail) {
        // A seal is set once, at the first hold. Re-applying a hold must not
        // re-seal with the current content — that would erase the evidence
        // that a held email was modified.
        guard evidenceSeals[email.id] == nil else { return }
        evidenceSeals[email.id] = Self.sealHash(email)
    }

    /// The seal value for an email (unchanged definition; shared by the
    /// single and batched paths so both produce identical seals).
    static func sealHash(_ email: MBOXParser.RawEmail) -> String {
        let content = email.headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            + "\n\n" + email.plainBody + email.htmlBody
        let hash = SHA256.hash(data: Data(content.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Holds + set-once seals for many emails with one assignment each.
    private func holdAndSealBatched(_ emails: [MBOXParser.RawEmail]) {
        var holds = legalHolds
        var seals = evidenceSeals
        for email in emails {
            holds.insert(email.id)
            if seals[email.id] == nil { seals[email.id] = Self.sealHash(email) }
        }
        legalHolds = holds
        evidenceSeals = seals
    }

    func verifyEvidenceSeal(_ email: MBOXParser.RawEmail) -> SealVerification {
        guard let storedHash = evidenceSeals[email.id] else {
            if isUnderLegalHold(email.id) {
                return .noSeal
            }
            return .notHeld
        }
        let content = email.headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            + "\n\n" + email.plainBody + email.htmlBody
        let hash = SHA256.hash(data: Data(content.utf8))
        let currentHash = hash.compactMap { String(format: "%02x", $0) }.joined()
        if currentHash == storedHash {
            return .intact
        }
        ForensicManager.shared.logAction("Evidence Seal BROKEN", detail: "Email \(email.id) content modified while under legal hold. Expected: \(storedHash.prefix(16))…, Got: \(currentHash.prefix(16))…")
        return .tampered(expected: storedHash, actual: currentHash)
    }

    enum SealVerification {
        case intact
        case tampered(expected: String, actual: String)
        case noSeal
        case notHeld
    }

    // MARK: - Centralized Enforcement

    func filterProtected(_ emailIDs: Set<UUID>) -> (allowed: Set<UUID>, blocked: Set<UUID>) {
        let blocked = emailIDs.filter { legalHolds.contains($0) }
        let allowed = emailIDs.subtracting(blocked)
        if !blocked.isEmpty {
            ForensicManager.shared.logAction("Legal Hold Enforced", detail: "\(blocked.count) email(s) protected from deletion/modification")
        }
        return (allowed, Set(blocked))
    }

    func filterProtected(_ emailIDs: [UUID]) -> (allowed: [UUID], blocked: [UUID]) {
        let blocked = emailIDs.filter { legalHolds.contains($0) }
        let allowed = emailIDs.filter { !legalHolds.contains($0) }
        if !blocked.isEmpty {
            ForensicManager.shared.logAction("Legal Hold Enforced", detail: "\(blocked.count) email(s) protected from deletion/modification")
        }
        return (allowed, blocked)
    }

    func removeEmailsSafely(from emails: inout [MBOXParser.RawEmail], removing ids: Set<UUID>) -> Int {
        let (allowed, blocked) = filterProtected(ids)
        let blockedCount = blocked.count
        emails.removeAll { allowed.contains($0.id) }
        if blockedCount > 0 {
            custodianLog.warning("\(blockedCount) email(s) under legal hold were not removed")
        }
        return blockedCount
    }

    // MARK: - Seal Persistence

    private func saveSeals() {
        do {
            let dict = evidenceSeals.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
            let data = try JSONEncoder().encode(dict)
            try data.write(to: sealsURL, options: .atomic)
        } catch {
            custodianLog.error("Failed to save evidence seals: \(error.localizedDescription)")
        }
    }

    private func loadSeals() {
        guard FileManager.default.fileExists(atPath: sealsURL.path) else { return }
        do {
            let data = try Data(contentsOf: sealsURL)
            let dict = try JSONDecoder().decode([String: String].self, from: data)
            var loaded: [UUID: String] = [:]
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    loaded[uuid] = value
                }
            }
            evidenceSeals = loaded
        } catch {
            custodianLog.error("Failed to decode evidence seals: \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    func custodianReport(emails: [MBOXParser.RawEmail]) -> String {
        var report = "Custodian Report\n"
        report += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        report += String(repeating: "=", count: 60) + "\n\n"

        for custodian in allCustodians {
            let ids = emailIDs(for: custodian)
            let custodianEmails = emails.filter { ids.contains($0.id) }
            report += "Custodian: \(custodian)\n"
            report += "  Emails: \(custodianEmails.count)\n"
            report += "  Legal Holds: \(custodianEmails.filter { legalHolds.contains($0.id) }.count)\n"
            report += "  Date Range: \(custodianEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted().first?.description ?? "N/A") — \(custodianEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted().last?.description ?? "N/A")\n\n"
        }

        let unassigned = emails.filter { custodians[$0.id] == nil }
        if !unassigned.isEmpty {
            report += "Unassigned: \(unassigned.count) emails\n"
        }

        return report
    }

    func clearAll() {
        custodians = [:]
        legalHolds = []
    }
}
