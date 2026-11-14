@testable import ArchiveCore
//
//  InvestigationReportData.swift
//  maxmailin
//
//  The numbers an investigation report draws, computed batch by batch.
//
//  §3-L13 (switch: `v3InvestigationReport`): the 3.0 engine feeds the whole
//  scope through `Accumulator` and draws the result; the previous path feeds
//  one array through the same accumulator. Each part mirrors the computation
//  the generator used to run over its array — same detectors, same
//  thresholds, same orderings — so a report over the same emails is the same
//  report. Memory grows with distinct senders, contacts, months and tags,
//  never with the number of emails.
//

import Foundation

extension InvestigationReportGenerator {

    struct ReportData {
        var totalEmails = 0
        var sentCount = 0
        var receivedCount = 0
        var uniqueDomains = 0
        var firstDate: Date?
        var lastDate: Date?
        var sentimentCount = 0
        var sentimentSum: Double = 0
        var sentimentPositive = 0
        var sentimentNegative = 0
        var classification: [EmailNLPEngine.EmailCategory: Int] = [:]
        var topSenders: [(address: String, count: Int)] = []
        var monthlyVolume: [(month: String, count: Int)] = []
        var contactDomains: [(name: String, count: Int, domains: [String])] = []
        var evidenceTags: [(tag: String, count: Int, emailIDs: [UUID])] = []
        var flaggedEmails: [FlaggedEmail] = []
        var heatmap = CommunicationHeatmapData(cells: [], maxCount: 0, totalEmails: 0)
        var sentimentTimeline = SentimentTimelineData(dataPoints: [])

        struct Accumulator {
            private var total = 0, sent = 0, received = 0
            private var domains = Set<String>()
            private var first: Date?, last: Date?
            private var sCount = 0, sSum: Double = 0, sPos = 0, sNeg = 0
            private var classification: [EmailNLPEngine.EmailCategory: Int] = [:]
            private var senders: [String: Int] = [:]
            private var months: [String: Int] = [:]
            private var contacts: [String: (count: Int, domains: Set<String>)] = [:]
            private var tagCounts: [String: Int] = [:]
            private var tagIDs: [String: [UUID]] = [:]
            private var flagged: [FlaggedEmail.Priority: [FlaggedEmail]] = [:]
            private var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
            private struct Period { var emails = 0, results = 0, pos = 0, neg = 0; var sum: Double = 0 }
            private var periods: [String: Period] = [:]
            private let monthFormatter: DateFormatter = {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
            }()

            init() {}

            /// Adds one batch. `keepEvidenceIDs` keeps per-tag id lists (the
            /// in-memory path did; the report only prints the counts).
            mutating func add(_ emails: [MBOXParser.RawEmail], keepEvidenceIDs: Bool = false) {
                let cal = Calendar.current
                total += emails.count
                for email in emails {
                    if email.messageType == "sent" { sent += 1 }
                    if email.messageType == "received" { received += 1 }
                    domains.formUnion(email.domains)

                    let date = MBOXParser.parseDate(email.headers["Date"])
                    if let date {
                        first = min(first ?? date, date)
                        last = max(last ?? date, date)
                        months[monthFormatter.string(from: date), default: 0] += 1
                        let weekday = cal.component(.weekday, from: date) - 1
                        let hour = cal.component(.hour, from: date)
                        if weekday >= 0 && weekday < 7 && hour >= 0 && hour < 24 { grid[weekday][hour] += 1 }
                        let c = cal.dateComponents([.year, .month], from: date)
                        if let y = c.year, let m = c.month {
                            periods["\(y)-\(String(format: "%02d", m))", default: Period()].emails += 1
                        }
                    }

                    let from = (email.headers["From"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !from.isEmpty { senders[from, default: 0] += 1 }

                    for field in ["From", "To", "Cc"] {
                        guard let value = email.headers[field] else { continue }
                        for addr in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !addr.isEmpty {
                            let normalized = addr.lowercased()
                            var entry = contacts[normalized] ?? (count: 0, domains: Set<String>())
                            if let at = addr.lastIndex(of: "@") {
                                let domain = addr[addr.index(after: at)...]
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "> \t\r\n")).lowercased()
                                if domain.contains(".") { entry.domains.insert(domain) }
                            }
                            entry.count += 1
                            contacts[normalized] = entry
                        }
                    }

                    for tag in email.tags where !tag.isEmpty {
                        tagCounts[tag, default: 0] += 1
                        if keepEvidenceIDs { tagIDs[tag, default: []].append(email.id) }
                    }
                    if !email.anomalies.isEmpty {
                        tagCounts["Anomaly Detected", default: 0] += 1
                        if keepEvidenceIDs { tagIDs["Anomaly Detected", default: []].append(email.id) }
                    }

                    addFlag(email)
                }

                for r in EmailNLPEngine.analyzeSentiment(of: emails) {
                    sCount += 1
                    sSum += r.score
                    if r.score > 0.4 { sPos += 1 }
                    if r.score < -0.4 { sNeg += 1 }
                    if let date = MBOXParser.parseDate(r.email.headers["Date"]) {
                        let c = cal.dateComponents([.year, .month], from: date)
                        if let y = c.year, let m = c.month {
                            let key = "\(y)-\(String(format: "%02d", m))"
                            periods[key, default: Period()].results += 1
                            periods[key, default: Period()].sum += r.score
                            if r.score > 0.2 { periods[key, default: Period()].pos += 1 }
                            if r.score < -0.2 { periods[key, default: Period()].neg += 1 }
                        }
                    }
                }
                for (category, n) in EmailNLPEngine.classifyAll(emails) { classification[category, default: 0] += n }
            }

            /// Same rules and order as the previous flagged list; only the
            /// first `maxSampleEmails` of each priority can ever be shown, so
            /// only those are kept (headers only).
            private mutating func addFlag(_ email: MBOXParser.RawEmail) {
                let limit = InvestigationReportGenerator.maxSampleEmails
                func keep(_ priority: FlaggedEmail.Priority, _ reason: String) {
                    guard flagged[priority, default: []].count < limit else { return }
                    var light = email
                    light.plainBody = ""; light.htmlBody = ""; light.rawSource = ""
                    light.mimeRoot = nil; light.isBodyCompacted = true
                    flagged[priority, default: []].append(FlaggedEmail(email: light, priority: priority, reason: reason))
                }
                if !email.anomalies.isEmpty {
                    keep(.high, "Anomalies: \(email.anomalies.joined(separator: ", "))")
                    return
                }
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let body = email.plainBody.lowercased()
                let urgencyPhrases = ["urgent", "immediately", "verify your account",
                                      "suspended", "act now", "click here", "confirm your identity"]
                let matched = urgencyPhrases.filter { subject.contains($0) || body.contains($0) }
                if !matched.isEmpty {
                    keep(.medium, "Suspicious language: \(matched.joined(separator: ", "))")
                    return
                }
                if email.attachments.count > 5 {
                    keep(.low, "High attachment count (\(email.attachments.count))")
                }
            }

            func finish() -> ReportData {
                var d = ReportData()
                d.totalEmails = total
                d.sentCount = sent
                d.receivedCount = received
                d.uniqueDomains = domains.count
                d.firstDate = first
                d.lastDate = last
                d.sentimentCount = sCount
                d.sentimentSum = sSum
                d.sentimentPositive = sPos
                d.sentimentNegative = sNeg
                d.classification = classification
                d.topSenders = senders.sorted { $0.value > $1.value }.prefix(15).map { (address: $0.key, count: $0.value) }
                d.monthlyVolume = months.sorted { $0.key < $1.key }.map { (month: $0.key, count: $0.value) }
                d.contactDomains = contacts.sorted { $0.value.count > $1.value.count }.prefix(15)
                    .map { (name: $0.key, count: $0.value.count, domains: Array($0.value.domains)) }
                d.evidenceTags = tagCounts.sorted { $0.value > $1.value }
                    .map { (tag: $0.key, count: $0.value, emailIDs: tagIDs[$0.key] ?? []) }
                d.flaggedEmails = Array(([.high, .medium, .low] as [FlaggedEmail.Priority])
                    .flatMap { flagged[$0] ?? [] }
                    .prefix(InvestigationReportGenerator.maxSampleEmails))

                let maxVal = grid.flatMap { $0 }.max() ?? 1
                var cells: [CommunicationHeatmapData.Cell] = []
                for day in 0..<7 {
                    for hour in 0..<24 {
                        let count = grid[day][hour]
                        cells.append(.init(dayOfWeek: day, hour: hour, count: count,
                                           normalizedIntensity: maxVal > 0 ? Double(count) / Double(maxVal) : 0))
                    }
                }
                d.heatmap = CommunicationHeatmapData(cells: cells, maxCount: maxVal, totalEmails: total)
                d.sentimentTimeline = SentimentTimelineData(dataPoints: periods.sorted { $0.key < $1.key }.map { key, p in
                    .init(period: key, averageSentiment: p.results == 0 ? 0 : p.sum / Double(p.results),
                          emailCount: p.emails, positiveCount: p.pos, negativeCount: p.neg)
                })
                return d
            }
        }
    }
}

/// §3-L13 engine: the report over the whole scope.
@MainActor
enum InvestigationReportEngine {
    struct Progress: Codable, Sendable { var emails = 0 }

    static func build(scope: ArchiveScope, title: String, investigator: String,
                      appendix: [InvestigationReportGenerator.AppendixSection] = [])
        async throws -> (pdf: Data, receipt: ScopeJobReceipt) {
        var acc = InvestigationReportGenerator.ReportData.Accumulator()
        let result = try await ScopeJob.run(
            key: "investigation.report", title: String(localized: "Investigation report"),
            capability: .v3InvestigationReport, query: scope.query, resumable: false, initialState: Progress()
        ) { state, batch in
            let current = acc
            acc = await Task.detached(priority: .userInitiated) {
                var next = current
                next.add(batch)
                return next
            }.value
            state.emails += batch.count
        }
        let data = acc.finish()
        let coverage = InvestigationReportGenerator.AppendixSection(
            title: String(localized: "Scope and coverage"),
            lines: result.receipt.documentFields.map { "\($0.key): \($0.value)" })
        let pdf = await Task.detached(priority: .userInitiated) {
            InvestigationReportGenerator.generateReport(data: data, title: title, investigatorName: investigator,
                                                        appendix: appendix + [coverage])
        }.value
        return (pdf, result.receipt)
    }
}
