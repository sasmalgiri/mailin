@testable import ArchiveCore
//
//  ArchiveQueryTools.swift
//  maxmailin
//
//  §3-I1 (switch: `v3AIAnswers`). FoundationModels tools that let the model
//  ASK the archive — the model chooses the question, our code counts, over the
//  whole archive (rule 8). Two short, focused tools (Apple's guidance: few
//  tools, short descriptions), added first so they survive the ≤ 5 trim.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, iOS 26, *)
struct CountEmailsTool: Tool {
    let name = "countEmails"
    let description = "Exact number of emails in the whole archive matching words, a sender, a recipient and/or a date range"

    @Generable
    struct Arguments {
        @Guide(description: "Words to search for, or empty")
        var words: String
        @Guide(description: "Sender name or address part, or empty")
        var sender: String
        @Guide(description: "Recipient name or address part, or empty")
        var recipient: String
        @Guide(description: "Start date yyyy-mm-dd, or empty")
        var from: String
        @Guide(description: "End date yyyy-mm-dd, or empty")
        var to: String
    }

    func call(arguments: Arguments) async throws -> String {
        var q = EmailQuery.all
        let words = arguments.words.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { q.text = words }
        if !arguments.sender.isEmpty { q.sender = arguments.sender }
        if !arguments.recipient.isEmpty { q.recipient = arguments.recipient }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: arguments.from) { q.afterDate = d }
        if let d = f.date(from: arguments.to) { q.beforeDate = d.addingTimeInterval(86_400) }
        let query = q
        let n = try await ArchiveDataService.shared.count(query: query)
        let total = try await ArchiveDataService.shared.count()
        return "\(n) of \(total) emails in the archive match (\(ScopeJob.describe(query)))."
    }
}

@available(macOS 26, iOS 26, *)
struct TopCorrespondentsTool: Tool {
    let name = "topCorrespondents"
    let description = "Who sends the most email in the whole archive: top senders or sender domains with exact counts, optionally within dates"

    @Generable
    struct Arguments {
        @Guide(description: "sender or domain")
        var groupBy: String
        @Guide(description: "Start date yyyy-mm-dd, or empty")
        var from: String
        @Guide(description: "End date yyyy-mm-dd, or empty")
        var to: String
    }

    func call(arguments: Arguments) async throws -> String {
        var q = EmailQuery.all
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: arguments.from) { q.afterDate = d }
        if let d = f.date(from: arguments.to) { q.beforeDate = d.addingTimeInterval(86_400) }
        let field: SQLiteEmailStore.GroupField = arguments.groupBy.lowercased().contains("domain") ? .domain : .sender
        let scoped = await MainActor.run { ArchiveDataService.shared.scoped(q) }
        let r = try await SQLiteEmailStore.shared.groupedCounts(query: scoped, by: field, limit: 10)
        guard !r.rows.isEmpty else { return "No emails in that range." }
        let lines = r.rows.enumerated().map { "\($0.offset + 1). \($0.element.value): \($0.element.count) emails" }
        return "Top \(r.rows.count) of \(r.distinct) \(field == .domain ? "domains" : "senders"):\n" + lines.joined(separator: "\n")
    }
}

@available(macOS 26, iOS 26, *)
enum ArchiveQueryTools {
    /// The counting tools first, then the intent's own tools, at most 5.
    static func merged(with tools: [any Tool]) -> [any Tool] {
        guard AIContextSelector.isEnabled else { return tools }
        return Array(([CountEmailsTool(), TopCorrespondentsTool()] as [any Tool] + tools).prefix(5))
    }
}
#endif
