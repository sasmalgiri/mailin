@testable import ArchiveCore
//
//  PersonalCleanupEngine.swift
//  maxmailin
//
//  §3-A10 (switch: `v3AnalysisQueries`). The Personal Organizer's cleanup
//  and storage figures over the WHOLE archive — these describe the mailbox,
//  not recent mail, so a newest-2,000 window under-counted them. Same rules
//  as the view: duplicate = same From|Subject|Date, large = body over 100,000
//  characters, attachment type = extension or MIME subtype. The triage and
//  "recent" sections keep using recent mail, which is what they are about.
//

import Foundation

struct PersonalCleanupStats: Sendable {
    var emails = 0
    var attachmentEmails = 0
    var attachmentTypes: [(String, Int)] = []
    var duplicates = 0
    var largeEmails = 0
    var noSubject = 0
    var bodyCharacters = 0
    var attachmentBytes = 0
}

@MainActor
enum PersonalCleanupEngine {
    private struct Progress: Codable, Sendable { var emails = 0 }

    static func compute(query: EmailQuery = .all) async throws -> (stats: PersonalCleanupStats, receipt: ScopeJobReceipt) {
        var s = PersonalCleanupStats()
        var seen = Set<UInt64>()
        var types: [String: Int] = [:]
        let result = try await ScopeJob.run(
            key: "personal.cleanup", title: String(localized: "Mailbox cleanup figures"),
            capability: .v3AnalysisQueries, query: query, resumable: false, initialState: Progress()
        ) { state, batch in
            for email in batch {
                s.emails += 1
                if !email.attachments.isEmpty { s.attachmentEmails += 1 }
                for att in email.attachments {
                    let ext = (att.filename as NSString).pathExtension.lowercased()
                    let type = ext.isEmpty ? att.mimeType.components(separatedBy: "/").last ?? "unknown" : ext
                    types[type, default: 0] += 1
                    s.attachmentBytes += att.size
                }
                let key = "\(email.headers["From"] ?? "")|\(email.headers["Subject"] ?? "")|\(email.headers["Date"] ?? "")"
                if !seen.insert(DistinctCounter.fnv1a(key)).inserted { s.duplicates += 1 }
                let body = email.plainBody.count + email.htmlBody.count
                s.bodyCharacters += body
                if body > 100_000 { s.largeEmails += 1 }
                if (email.headers["Subject"] ?? "").isEmpty { s.noSubject += 1 }
            }
            state.emails += batch.count
        }
        s.attachmentTypes = types.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return (s, result.receipt)
    }
}
