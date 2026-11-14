@testable import ArchiveCore
//
//  DigestEngine.swift
//  maxmailin
//
//  §3-A17 (switch: `v3AnalysisQueries`). The AI Digest over the WHOLE period.
//
//  The previous digest read the newest 1,000 emails of the scope and then
//  filtered them to the period in memory, so "Last 30 days" on a busy archive
//  described the last few days, and on an archive whose newest mail is old it
//  was empty. Here the period is a date bound on the query and every email in
//  it is streamed once, batch by batch, into running totals (memory stays
//  flat): counts, busiest day and hour, top senders, conversations, action
//  items, new contacts, sentiment and attachments are exact. Lists show their
//  top entries and say "N of M". New contacts are checked against the whole
//  archive before the period. The AI narrates code-computed figures (rule 8).
//

import Foundation

@MainActor
enum DigestEngine {
    typealias Section = AIDigestGenerator.DigestSection
    typealias Item = AIDigestGenerator.DigestItem

    /// The period as date bounds on `base` (narrowing it, never widening).
    static func periodQuery(_ base: EmailQuery, period: AIDigestGenerator.TimePeriod,
                            customStart: Date?, customEnd: Date?, now: Date = Date()) -> EmailQuery {
        let calendar = Calendar.current
        let lower: Date
        var upper = now.addingTimeInterval(1)
        switch period {
        case .today: lower = calendar.startOfDay(for: now)
        case .lastWeek: lower = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .lastMonth: lower = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .custom:
            lower = calendar.startOfDay(for: customStart ?? calendar.date(byAdding: .day, value: -7, to: now) ?? now)
            if let e = customEnd, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e)) { upper = end }
        }
        var q = base
        q.afterDate = q.afterDate.map { max($0, lower) } ?? lower
        q.beforeDate = q.beforeDate.map { min($0, upper) } ?? upper
        return q
    }

    private struct Thread { var count = 0; var participants: Set<String> = []; var ids: [UUID] = [] }
    private struct Contact { var display: String; var ids: [UUID] }
    private struct Pick { var score: Double; var subject: String; var from: String; var id: UUID }
    private struct Big { var size: Int; var subject: String; var files: String; var id: UUID }

    private static let urgentKeywords = ["urgent", "asap", "action required", "deadline", "critical", "immediate",
                                         "time-sensitive", "respond by", "reply by", "due date", "overdue"]
    private static let questionKeywords = ["?", "could you", "can you", "would you", "please", "do you", "are you able"]

    /// `narrate`: add the on-device model's insights (tests pass false).
    static func digest(query: EmailQuery, batchSize: Int = 200, narrate: Bool = true) async throws -> [Section] {
        let archive = ScopeJobEnvironment.archive
        let token = EngineGuard.begin(.v3AnalysisQueries)
        defer { EngineGuard.end(token) }

        var total = 0, sent = 0
        var senders: [String: Int] = [:]
        var days: [String: Int] = [:]
        var hours: [Int: Int] = [:]
        var threads: [String: Thread] = [:]
        var urgent: [Item] = [], questions: [Item] = []
        var urgentTotal = 0, questionTotal = 0
        var contacts: [String: Contact] = [:]
        var sentimentSum = 0.0, sentimentN = 0, positive = 0, negative = 0
        var mostPositive: Pick?, mostNegative: Pick?
        var withFiles = 0, files = 0
        var fileTypes: [String: Int] = [:]
        var biggest: [Big] = []
        var newest: [MBOXParser.RawEmail] = []

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        for try await batch in archive.streamFullEmails(query: query, batchSize: AdaptiveBatch.size(requested: batchSize)) {
            try Task.checkCancellation()
            if newest.isEmpty { newest = Array(batch.prefix(20)) }
            let scores = await Task.detached(priority: .userInitiated) { EmailNLPEngine.analyzeSentiment(of: batch) }.value
            for r in scores {
                sentimentSum += r.score; sentimentN += 1
                if r.score > 0.4 { positive += 1 } else if r.score < -0.4 { negative += 1 }
                let pick = Pick(score: r.score, subject: r.email.headers["Subject"] ?? "(No Subject)",
                                from: r.email.headers["From"] ?? "Unknown", id: r.email.id)
                if r.score > (mostPositive?.score ?? -.infinity) { mostPositive = pick }
                if r.score < (mostNegative?.score ?? .infinity) { mostNegative = pick }
            }
            for email in batch {
                total += 1
                if email.messageType == "sent" { sent += 1 }
                let from = email.headers["From"] ?? "Unknown"
                senders[from, default: 0] += 1
                if let d = MBOXParser.parseDate(email.headers["Date"]) {
                    days[dayFormatter.string(from: d), default: 0] += 1
                    hours[Calendar.current.component(.hour, from: d), default: 0] += 1
                }
                let subject = AIDigestGenerator.normalizeSubject(email.headers["Subject"] ?? "(No Subject)")
                threads[subject, default: Thread()].count += 1
                threads[subject]?.participants.insert(from)
                threads[subject]?.ids.append(email.id)

                let lowerSubject = (email.headers["Subject"] ?? "").lowercased()
                let prefix = String(AIDigestGenerator.bodyText(for: email).lowercased().prefix(1000))
                let hits = urgentKeywords.filter { lowerSubject.contains($0) || prefix.contains($0) }
                if !hits.isEmpty {
                    urgentTotal += 1
                    if urgent.count < 10 {
                        urgent.append(Item(headline: email.headers["Subject"] ?? "(No Subject)",
                                           detail: "From \(from) — contains: \(hits.joined(separator: ", "))",
                                           emailIDs: [email.id], priority: .high))
                    }
                } else if questionKeywords.filter({ prefix.contains($0) }).count >= 2 {
                    questionTotal += 1
                    if questions.count < 10 {
                        questions.append(Item(headline: email.headers["Subject"] ?? "(No Subject)",
                                              detail: "From \(from) — contains questions that may need a response",
                                              emailIDs: [email.id], priority: .medium))
                    }
                }

                let address = AIDigestGenerator.extractEmailAddress(from: from).lowercased()
                if !address.isEmpty {
                    contacts[address, default: Contact(display: from, ids: [])].ids.append(email.id)
                }

                if !email.attachments.isEmpty {
                    withFiles += 1
                    files += email.attachments.count
                    for a in email.attachments { fileTypes[category(of: a.filename), default: 0] += 1 }
                    let size = email.attachments.reduce(0) { $0 + $1.size }
                    if size > 0 {
                        biggest.append(Big(size: size, subject: email.headers["Subject"] ?? "(No Subject)",
                                           files: email.attachments.map(\.filename).joined(separator: ", "), id: email.id))
                        biggest.sort { $0.size > $1.size }
                        if biggest.count > 3 { biggest.removeLast() }
                    }
                }
            }
            await Task.yield()
        }
        guard total > 0 else { return [] }

        var sections: [Section] = []
        sections.append(statistics(total: total, sent: sent, senders: senders, days: days, hours: hours))

        let top = threads.sorted { $0.value.count > $1.value.count }.prefix(5)
        if !top.isEmpty {
            var items = top.map { subject, t in
                let names = t.participants.sorted().prefix(3).joined(separator: ", ")
                let more = t.participants.count > 3 ? " +\(t.participants.count - 3) more" : ""
                return Item(headline: subject, detail: "\(t.count) messages with \(names)\(more)", emailIDs: t.ids,
                            priority: t.count > 10 ? .high : (t.count > 5 ? .medium : .low))
            }
            items.append(Item(headline: String(localized: "\(top.count) of \(threads.count) conversations shown"),
                              detail: "", emailIDs: [], priority: .low))
            sections.append(Section(title: String(localized: "Key Conversations"), icon: "bubble.left.and.bubble.right.fill", items: items))
        }

        if urgentTotal + questionTotal > 0 {
            let shown = Array((urgent + questions).prefix(10))
            let items = shown + [Item(headline: String(localized: "\(shown.count) of \(urgentTotal + questionTotal) shown — \(urgentTotal) urgent, \(questionTotal) with questions"),
                                      detail: "", emailIDs: [], priority: .low)]
            sections.append(Section(title: String(localized: "Action Items"), icon: "exclamationmark.bubble.fill", items: items))
        }

        // New contacts: no email from the address anywhere in the archive
        // before the period starts.
        var fresh: [(String, Contact)] = []
        if let periodStart = query.afterDate {
            for (address, contact) in contacts {
                var before = EmailQuery.all
                before.sender = address
                before.beforeDate = periodStart
                if try await archive.count(query: before) == 0 { fresh.append((address, contact)) }
            }
        }
        if !fresh.isEmpty {
            let ranked = fresh.sorted { $0.1.ids.count > $1.1.ids.count }
            var items = ranked.prefix(10).map { _, c in
                Item(headline: c.display, detail: "\(c.ids.count) email\(c.ids.count == 1 ? "" : "s") from new contact",
                     emailIDs: c.ids, priority: c.ids.count > 3 ? .medium : .low)
            }
            items.append(Item(headline: String(localized: "\(min(10, ranked.count)) of \(ranked.count) new contacts shown"),
                              detail: "", emailIDs: [], priority: .low))
            sections.append(Section(title: String(localized: "New Contacts"), icon: "person.badge.plus", items: items))
        }

        if sentimentN > 0 {
            let avg = sentimentSum / Double(sentimentN)
            let label = avg > 0.4 ? "Positive" : (avg < -0.4 ? "Negative" : "Neutral")
            var items = [Item(headline: "Overall tone: \(label)",
                              detail: "Average sentiment score: \(String(format: "%.2f", avg)) over \(sentimentN) emails. \(positive) positive, \(sentimentN - positive - negative) neutral, \(negative) negative.",
                              emailIDs: [], priority: .medium)]
            if let p = mostPositive, p.score > 0.4 {
                items.append(Item(headline: "Most positive: \(p.subject)", detail: "From \(p.from) — sentiment: \(String(format: "%.2f", p.score))", emailIDs: [p.id], priority: .low))
            }
            if let n = mostNegative, n.score < -0.4 {
                items.append(Item(headline: "Most negative: \(n.subject)", detail: "From \(n.from) — sentiment: \(String(format: "%.2f", n.score))", emailIDs: [n.id], priority: .low))
            }
            sections.append(Section(title: String(localized: "Sentiment Summary"), icon: "face.smiling", items: items))
        }

        if withFiles > 0 {
            var items = [Item(headline: "\(files) attachments in \(withFiles) emails",
                              detail: "Average \(String(format: "%.1f", Double(files) / Double(withFiles))) attachments per email with files",
                              emailIDs: [], priority: .low)]
            if !fileTypes.isEmpty {
                items.append(Item(headline: String(localized: "File types"),
                                  detail: fileTypes.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", "),
                                  emailIDs: [], priority: .low))
            }
            for b in biggest {
                items.append(Item(headline: b.subject, detail: "Files: \(b.files) (\(AIDigestGenerator.formatSize(b.size)))",
                                  emailIDs: [b.id], priority: b.size > 5_000_000 ? .medium : .low))
            }
            sections.append(Section(title: String(localized: "Attachments Overview"), icon: "paperclip", items: items))
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), let whatsNew = AIDigestGenerator.whatsNewSection() {
            sections.insert(whatsNew, at: min(3, sections.count))
        }
        #endif

        // Predictions: the whole-period predictive engine (§3-A3).
        if let predicted = try? await PredictiveInsightsEngine.analyze(query: query) {
            let lines = PredictiveEngine.digestItems(summary: predicted.summary)
            if !lines.isEmpty {
                sections.append(Section(title: String(localized: "Predictions & Alerts"), icon: "chart.line.uptrend.xyaxis",
                                        items: lines.map { Item(headline: $0.title, detail: $0.detail, emailIDs: [],
                                                                priority: $0.priority >= 2 ? .high : ($0.priority >= 1 ? .medium : .low)) }))
            }
        }

        // AI: narrates the figures above (counts in code, rule 8), reading
        // the newest emails of the period for colour — and says so.
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), narrate {
            let facts = "Period totals (exact): \(total) emails, \(sent) sent, \(total - sent) received; "
                + "\(urgentTotal) urgent, \(questionTotal) with questions; \(fresh.count) new contacts; \(withFiles) with attachments."
            if let text = await FoundationModelEngine.enhanceWithAI(scope: .digest, emails: newest,
                                                                     context: "Generate insights for email digest. " + facts) {
                var items = text.components(separatedBy: "\n").filter { !$0.isEmpty }.map { line in
                    Item(headline: line, detail: "", emailIDs: [],
                         priority: line.hasPrefix("▲") ? .high : (line.hasPrefix("●") ? .medium : .low))
                }
                if !items.isEmpty {
                    items.append(Item(headline: String(localized: "The model read the newest \(newest.count) of \(total) emails; the figures cover all \(total)."),
                                      detail: "", emailIDs: [], priority: .low))
                    sections.append(Section(title: String(localized: "AI Insights"), icon: "sparkles", items: items))
                }
            }
        }
        #endif
        return sections
    }

    private static func statistics(total: Int, sent: Int, senders: [String: Int],
                                   days: [String: Int], hours: [Int: Int]) -> Section {
        var items = [Item(headline: "Total: \(total) emails", detail: "\(sent) sent, \(total - sent) received", emailIDs: [], priority: .medium)]
        if let d = days.max(by: { $0.value < $1.value }) {
            items.append(Item(headline: "Busiest day: \(d.key)", detail: "\(d.value) emails on \(d.key)s", emailIDs: [], priority: .low))
        }
        if let h = hours.max(by: { $0.value < $1.value }) {
            let label = h.key < 12 ? "\(h.key == 0 ? 12 : h.key) AM" : "\(h.key == 12 ? 12 : h.key - 12) PM"
            items.append(Item(headline: "Peak hour: \(label)", detail: "\(h.value) emails around \(label)", emailIDs: [], priority: .low))
        }
        let top = senders.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3)
        if !top.isEmpty {
            items.append(Item(headline: String(localized: "Top senders"),
                              detail: top.map { "\($0.key) (\($0.value))" }.joined(separator: ", ") + " — \(senders.count) senders in all",
                              emailIDs: [], priority: .low))
        }
        return Section(title: String(localized: "Statistics"), icon: "chart.bar.fill", items: items)
    }

    private static func category(of filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "PDF" }
        if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"].contains(ext) { return "Images" }
        if ["doc", "docx", "rtf", "txt"].contains(ext) { return "Documents" }
        if ["xls", "xlsx", "csv"].contains(ext) { return "Spreadsheets" }
        if ["zip", "gz", "tar", "7z", "rar"].contains(ext) { return "Archives" }
        return ext.isEmpty ? "Unknown" : ext.uppercased()
    }
}
