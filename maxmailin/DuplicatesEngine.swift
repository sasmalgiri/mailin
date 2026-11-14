@testable import ArchiveCore
//
//  DuplicatesEngine.swift
//  maxmailin
//
//  §3-L19 (switch: `v3Duplicates`). Exact-duplicate groups over the WHOLE
//  archive instead of the newest 5,000. Same two keys as before — the
//  Message-ID, then SHA-1 of From + Subject + Date + the first 200 body
//  characters, then (§3-Q3) the EDRM Message Identification Hash, which
//  matches the same message imported from different sources — and the same grouping rule (Message-ID groups first; an
//  email joins at most one group). Pass 1 keeps only small keys per email
//  (8-byte digests of the keys); pass 2 loads just the emails that are in a
//  group, so memory follows the number of duplicates, not the archive.
//
//  Groups are listed, never deleted automatically; removal still goes
//  through the legal-hold-aware path.
//

import Foundation

@MainActor
enum DuplicatesEngine {
    struct Keys: Codable, Sendable {
        var byMessageID: [UInt64: [UUID]] = [:]
        var byContent: [UInt64: [UUID]] = [:]
        /// §3-Q3: EDRM MIH — the same message from different sources.
        var byMIH: [UInt64: [UUID]] = [:]
    }

    static func exactGroups(query: EmailQuery = .all) async throws -> (groups: [[MBOXParser.RawEmail]], receipt: ScopeJobReceipt) {
        let result = try await ScopeJob.run(
            key: "duplicates.exact", title: String(localized: "Find duplicates"),
            capability: .v3Duplicates, query: query, resumable: false, initialState: Keys()
        ) { state, batch in
            for email in batch {
                if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"], !msgID.isEmpty {
                    state.byMessageID[DistinctCounter.fnv1a(msgID), default: []].append(email.id)
                }
                let content = MBOXParser.sha1(
                    (email.headers["From"] ?? "") + (email.headers["Subject"] ?? "")
                    + (email.headers["Date"] ?? "") + String(email.plainBody.prefix(200)))
                state.byContent[DistinctCounter.fnv1a(content), default: []].append(email.id)
                let body = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
                state.byMIH[DistinctCounter.fnv1a(FeatureExtractor.messageIdentificationHash(email, bodyText: body)), default: []].append(email.id)
            }
        }
        // Same rule as before: Message-ID groups first, an email in one group only.
        var groupsOfIDs: [[UUID]] = []
        var seen = Set<UUID>()
        for ids in result.state.byMessageID.values where ids.count > 1 && !ids.contains(where: seen.contains) {
            groupsOfIDs.append(ids); seen.formUnion(ids)
        }
        for ids in result.state.byContent.values where ids.count > 1 && !ids.contains(where: seen.contains) {
            groupsOfIDs.append(ids); seen.formUnion(ids)
        }
        for ids in result.state.byMIH.values where ids.count > 1 && !ids.contains(where: seen.contains) {
            groupsOfIDs.append(ids); seen.formUnion(ids)
        }
        // Load only the members of groups.
        var byID: [UUID: MBOXParser.RawEmail] = [:]
        let members = groupsOfIDs.flatMap { $0 }
        var start = 0
        while start < members.count {
            let chunk = Array(members[start..<min(start + 500, members.count)])
            for email in try await ScopeJobEnvironment.archive.fullEmails(ids: chunk) { byID[email.id] = email }
            start += chunk.count
        }
        let groups = groupsOfIDs.map { $0.compactMap { byID[$0] } }.filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
        return (groups, result.receipt)
    }
}
