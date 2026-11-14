@testable import ArchiveCore
//
//  ArchiveQueryTools.swift
//  maxmailin
//
//  §3-I1 (switch: `v3AIAnswers`). FoundationModels tools that let the model
//  ASK the archive — the model chooses the question, our code counts, over the
//  whole archive (rule 8). Three short, focused tools — count, top-K and
//  timeline (find is the intent's own search tool); Apple's guidance: few
//  tools, short descriptions. Added first so they survive the ≤ 5 trim.
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
        let n = try await ScopeJobEnvironment.archive.count(query: query)
        let total = try await ScopeJobEnvironment.archive.count()
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
        let query = q
        let scoped = await MainActor.run { ScopeJobEnvironment.archive.scoped(query) }
        let r = try await ScopeJobEnvironment.store.groupedCounts(query: scoped, by: field, limit: 10)
        guard !r.rows.isEmpty else { return "No emails in that range." }
        let lines = r.rows.enumerated().map { "\($0.offset + 1). \($0.element.value): \($0.element.count) emails" }
        return "Top \(r.rows.count) of \(r.distinct) \(field == .domain ? "domains" : "senders"):\n" + lines.joined(separator: "\n")
    }
}

@available(macOS 26, iOS 26, *)
struct EmailTimelineTool: Tool {
    let name = "emailTimeline"
    let description = "How many emails per month (or per year for long spans) in the whole archive, optionally for words, a sender or dates"

    @Generable
    struct Arguments {
        @Guide(description: "Words to search for, or empty")
        var words: String
        @Guide(description: "Sender name or address part, or empty")
        var sender: String
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
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: arguments.from) { q.afterDate = d }
        if let d = f.date(from: arguments.to) { q.beforeDate = d.addingTimeInterval(86_400) }
        let query = q
        let months = try await EmailTimelineTool.monthlyCounts(query)
        return EmailTimelineTool.render(months, scope: ScopeJob.describe(query))
    }

    /// Counts per "yyyy-MM": SQL for non-text scopes; text scopes are counted
    /// from their hits (summaries only, flat memory).
    static func monthlyCounts(_ query: EmailQuery) async throws -> [(month: String, count: Int)] {
        let archive = ScopeJobEnvironment.archive
        let scoped = await MainActor.run { archive.scoped(query) }
        if scoped.text?.isEmpty ?? true {
            return try await ScopeJobEnvironment.store.monthlyCounts(query: scoped).map { (month: $0.value, count: $0.count) }
        }
        var counts: [String: Int] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        let stream = await MainActor.run { archive.streamSummaries(query: scoped, batchSize: 5_000) }
        for try await page in stream {
            for s in page { counts[f.string(from: s.date), default: 0] += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { (month: $0.key, count: $0.value) }
    }

    /// Up to 36 months are listed as months; longer spans as years, so the
    /// answer fits the on-device model's window. Totals are exact either way.
    static func render(_ months: [(month: String, count: Int)], scope: String) -> String {
        let total = months.reduce(0) { $0 + $1.count }
        guard !months.isEmpty else { return "No emails match (\(scope))." }
        if months.count <= 36 {
            return "\(total) emails (\(scope)), per month:\n" + months.map { "\($0.month): \($0.count)" }.joined(separator: "\n")
        }
        var years: [String: Int] = [:]
        for m in months { years[String(m.month.prefix(4)), default: 0] += m.count }
        return "\(total) emails (\(scope)) over \(months.count) months, per year:\n"
            + years.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

@available(macOS 26, iOS 26, *)
enum ArchiveQueryTools {
    /// The counting tools first, then the intent's own tools, at most 5.
    static func merged(with tools: [any Tool]) -> [any Tool] {
        guard AIContextSelector.isEnabled else { return tools }
        return Array(([CountEmailsTool(), TopCorrespondentsTool(), EmailTimelineTool()] as [any Tool] + tools).prefix(5))
    }
}
#endif
