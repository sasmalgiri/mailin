//
//  TeamCaseShared.swift
//  maxmailin
//
//  3.0 B7 (team case, switch `v31TeamCase`):
//  T2  — under MDM the reviewer's name comes from the managed configuration
//        (examinerName), not from what was typed; the role already does.
//  T9  — shared redaction profiles: the lead stores named rule sets in the
//        case folder, signed with the lead's key; every member loads them,
//        and a file whose signature does not match the case's lead is refused.
//  T11 — "Verify audit": every log in the folder is read again from disk and
//        each entry's signature and chain re-checked, with the result per member.
//

import Foundation
import CryptoKit

// MARK: - T2 identity

enum TeamIdentity {
    /// The name written into every log entry, and whether the person may change it.
    static func name(typed: String, managed: String? = ManagedConfig.examinerName) -> (name: String, managed: Bool) {
        if let m = managed?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return (m, true) }
        return (typed.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }
}

// MARK: - T9 shared redaction profiles

struct SharedRedactionProfile: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var rules: [RedactionEngine.RedactionRule]
    var savedBy: String
    var savedAt: Date
}

enum SharedRedactionError: LocalizedError, Equatable {
    case onlyTheLead
    case tampered
    case unreadable

    var errorDescription: String? {
        switch self {
        case .onlyTheLead: return String(localized: "Only the case lead can change the shared redaction profiles.")
        case .tampered: return String(localized: "The shared redaction profiles were not signed by this case's lead; they were not used.")
        case .unreadable: return String(localized: "The shared redaction profiles file could not be read.")
        }
    }
}

extension TeamCase {
    private struct ProfilesFile: Codable { var payload: String; var signature: String; var signer: String }

    var redactionProfilesURL: URL { folder.appendingPathComponent("redaction-profiles.json") }
    var isLead: Bool { myKey == manifest.leadKey }

    /// The case's shared profiles; empty when none were saved. Refused when the
    /// file was not signed by the lead named in the manifest.
    func redactionProfiles() throws -> [SharedRedactionProfile] {
        guard FileManager.default.fileExists(atPath: redactionProfilesURL.path) else { return [] }
        guard let data = try? Data(contentsOf: redactionProfilesURL),
              let file = try? TeamCaseIO.decoder.decode(ProfilesFile.self, from: data),
              let payload = Data(base64Encoded: file.payload) else { throw SharedRedactionError.unreadable }
        guard file.signer == manifest.leadKey,
              let keyData = Data(base64Encoded: file.signer),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: file.signature),
              key.isValidSignature(sig, for: payload) else { throw SharedRedactionError.tampered }
        guard let profiles = try? TeamCaseIO.decoder.decode([SharedRedactionProfile].self, from: payload) else {
            throw SharedRedactionError.unreadable
        }
        return profiles
    }

    /// Adds or replaces a profile by name (lead only), signed, written atomically.
    func saveRedactionProfile(name: String, rules: [RedactionEngine.RedactionRule]) throws {
        guard isLead else { throw SharedRedactionError.onlyTheLead }
        var profiles = (try? redactionProfiles()) ?? []
        profiles.removeAll { $0.name == name }
        profiles.append(SharedRedactionProfile(name: name, rules: rules, savedBy: myName, savedAt: Date()))
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let payload = try TeamCaseIO.encoder.encode(profiles)
        let file = ProfilesFile(payload: payload.base64EncodedString(), signature: try sign(payload), signer: myKey)
        try TeamCaseIO.atomicWrite(try TeamCaseIO.encoder.encode(file), to: redactionProfilesURL)
        try append(.note, value: "Shared redaction profile saved: \(name) (\(rules.count) rules)", state: load())
    }
}

/// The case open in Team case, and the profile its member chose for Redaction.
@MainActor
enum TeamCaseSession {
    static var open: TeamCase?
    static var chosenProfile: (caseTitle: String, profile: SharedRedactionProfile)?
}

// MARK: - T11 audit verification

struct TeamAuditCheck: Equatable, Sendable {
    struct Log: Equatable, Sendable {
        var file: String
        var member: String
        var verifiedEntries: Int
        var problems: [String]
        var ok: Bool { problems.isEmpty }
    }
    var logs: [Log]
    var checkedAt: Date
    var totalEntries: Int { logs.reduce(0) { $0 + $1.verifiedEntries } }
    var ok: Bool { logs.allSatisfy(\.ok) }

    var summary: String {
        ok ? String(localized: "\(logs.count) logs, \(totalEntries) entries: every signature and chain verified.")
           : String(localized: "\(logs.filter { !$0.ok }.count) of \(logs.count) logs have problems; \(totalEntries) entries verified before them.")
    }
}

extension TeamCase {
    /// Reads every log again from disk (no cache) and re-checks each entry.
    func verifyAudit(now: Date = Date()) -> TeamAuditCheck {
        let files = ((try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var logs: [TeamAuditCheck.Log] = []
        for f in files {
            let (entries, problems) = Self.readLog(f)
            var issues = problems
            // A log must be its author's own file: the name is the author's key id.
            if let author = entries.first?.author, TeamCaseIO.keyID(author) + ".jsonl" != f.lastPathComponent {
                issues.append(String(localized: "\(f.lastPathComponent): written by a key that is not this file's owner"))
            }
            logs.append(.init(file: f.lastPathComponent, member: entries.last?.authorName ?? "—",
                              verifiedEntries: entries.count, problems: issues))
        }
        return TeamAuditCheck(logs: logs, checkedAt: now)
    }
}
