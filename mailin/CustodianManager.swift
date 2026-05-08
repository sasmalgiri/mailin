import Foundation
import SwiftUI
import os.log

private let custodianLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "Custodian")

@MainActor
class CustodianManager: ObservableObject {
    static let shared = CustodianManager()

    @Published var custodians: [UUID: String] = [:] { didSet { saveCustodians() } }
    @Published var legalHolds: Set<UUID> = [] { didSet { saveLegalHolds() } }

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

    private init() {
        loadCustodians()
        loadLegalHolds()
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
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    custodians[uuid] = value
                }
            }
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
        for id in emailIDs {
            custodians[id] = name
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

    func removeLegalHold(_ emailID: UUID) {
        legalHolds.remove(emailID)
        ForensicManager.shared.logAction("Legal Hold Removed", detail: "Legal hold removed from email \(emailID)")
    }

    func isUnderLegalHold(_ emailID: UUID) -> Bool {
        legalHolds.contains(emailID)
    }

    func placeLegalHold(on emailIDs: [UUID]) {
        for id in emailIDs {
            legalHolds.insert(id)
        }
        ForensicManager.shared.logAction("Legal Hold Placed", detail: "Legal hold placed on \(emailIDs.count) emails")
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
