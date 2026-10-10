@testable import ArchiveCore
//
//  AIContextSelector.swift
//  maxmailin
//
//  §3-I3 / §3-I4 (switch: `v3AIAnswers`). Which emails an AI enhancement
//  reads. The experts compute their figures in code from the emails they
//  are given and the model narrates a digest (rule 8), so the choice of
//  emails decides what the answer can know. Previously: the tool's loaded
//  window or the newest 200–500. Now:
//   • security → the most relevant emails for security signals, found by the
//     full-text index across the whole archive;
//   • everything else → emails spread evenly across the whole archive;
//  and the answer states how many emails of how many it was based on.
//

import Foundation

@MainActor
enum AIContextSelector {
    nonisolated(unsafe) static var isEnabled = false
    static let defaultCount = 500

    static let securityQuery = "password OR verify OR urgent OR invoice OR wire OR suspended OR login OR account OR phishing OR attachment"

    struct Selection {
        var emails: [MBOXParser.RawEmail]
        var total: Int
        var how: String
        var note: String { String(localized: "Based on \(emails.count) of \(total) emails (\(how)).") }
    }

    /// The emails an AI answer reads, and the "based on" line (nil = the
    /// caller's emails as given). A scope the user chose is always kept; a
    /// window is replaced only while the 3.0 engine is on.
    static func context(for emails: [MBOXParser.RawEmail], isWindow: Bool, scopeName: String,
                        enabled: Bool = isEnabled) async -> (emails: [MBOXParser.RawEmail], basedOn: String?) {
        guard enabled, isWindow, let selection = await select(for: scopeName) else { return (emails, nil) }
        return (selection.emails, selection.note)
    }

    static func select(for scopeName: String, count: Int = defaultCount) async -> Selection? {
        let total = (try? await ScopeJobEnvironment.archive.count()) ?? 0
        guard total > 0 else { return nil }
        if scopeName == "security",
           let hits = try? await ArchiveRetrievalService.shared.retrieve(securityQuery, limit: count), !hits.isEmpty {
            return Selection(emails: hits.map(\.email), total: total,
                             how: String(localized: "the most relevant for security signals, from the whole archive"))
        }
        guard let sample = try? await ArchiveSample.evenlySpaced(size: count) else { return nil }
        return Selection(emails: sample.emails, total: sample.total,
                         how: String(localized: "spread evenly across the whole archive"))
    }
}
