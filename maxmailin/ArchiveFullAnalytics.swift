//
//  ArchiveFullAnalytics.swift
//  maxmailin
//
//  Stage 5 W3 / Engine cutover 3 (v2-core-cutover): the scope-aware, bounded
//  replacement for EmailAnalyticsView's in-RAM `[RawEmail]` computation.
//
//  Two entry points share ONE `TallyAccumulator`, so the streaming and array
//  paths are identical by construction:
//   • compute(emails:)  — array path; also the correctness ORACLE.
//   • compute(scope:)    — streams the scope from SQLite in bounded pages,
//                          folding exact tallies (totals, timeline, contacts,
//                          heatmap, attachments, domains, sizes, relationships,
//                          storage) while holding only one page at a time.
//
//  The NLP analytics (sentiment, languages, topics, PII, priorities) are
//  corpus-level text algorithms; the streaming path runs them over a bounded
//  most-recent working set of the scope (`nlpCap`), which is representative and
//  keeps memory flat regardless of archive size. The order-independent nature of
//  those aggregates (counts / averages / distributions) means array-vs-streaming
//  agree exactly whenever the scope fits within `nlpCap`.
//

import Foundation
import SwiftUI

@MainActor
final class ArchiveFullAnalyticsService {

    static let shared = ArchiveFullAnalyticsService(service: .shared)

    static let defaultNLPCap = 5000

    private let service: ArchiveDataService
    init(service: ArchiveDataService) { self.service = service }

    // MARK: - Public entry points

    /// Array path (also used as the oracle and for legacy filtered selections).
    func compute(emails: [MBOXParser.RawEmail]) async -> AnalyticsData {
        var acc = TallyAccumulator()
        for e in emails { acc.ingest(e) }
        var data = acc.finalize()
        await applyNLP(to: &data, over: emails)
        return data
    }

    /// Streaming path — bounded tallies over the whole scope + NLP over a
    /// bounded most-recent working set. Peak residency is one page + `nlpCap`.
    func compute(scope query: EmailQuery = .all,
                 nlpCap: Int = defaultNLPCap,
                 batchSize: Int = 500) async throws -> AnalyticsData {
        var acc = TallyAccumulator()
        var workingSet: [MBOXParser.RawEmail] = []
        workingSet.reserveCapacity(min(nlpCap, 1024))

        let stream = service.streamFullEmails(query: query, batchSize: batchSize)
        for try await batch in stream {
            for e in batch {
                acc.ingest(e)
                if workingSet.count < nlpCap { workingSet.append(e) }
            }
        }
        var data = acc.finalize()
        await applyNLP(to: &data, over: workingSet)
        return data
    }

    // MARK: - NLP (shared by both paths)

    private func applyNLP(to data: inout AnalyticsData, over emails: [MBOXParser.RawEmail]) async {
        let sentiment = EmailNLPEngine.averageSentiment(of: emails)
        data.avgSentiment = sentiment.average
        data.sentimentLabel = sentiment.label
        data.sentimentBuckets = [
            SentimentBucket(label: "Positive", count: sentiment.positive, color: .green),
            SentimentBucket(label: "Neutral", count: sentiment.neutral, color: .gray),
            SentimentBucket(label: "Negative", count: sentiment.negative, color: .red)
        ]
        data.languages = await EmailNLPEngine.detectLanguagesHybrid(in: emails)
        data.topTopics = EmailNLPEngine.extractTopics(from: emails, limit: 12)
        data.piiCounts = EmailNLPEngine.piiSummary(in: emails)
        let priorities = EmailNLPEngine.scoreAllPriorities(emails)
        data.highPriorityCount = priorities.filter { $0.level == .high }.count
        data.mediumPriorityCount = priorities.filter { $0.level == .medium }.count
    }

    // MARK: - Exact tally accumulator (single source of truth)

    /// Folds emails into compact maps; `finalize()` reproduces exactly the
    /// sort/prefix/ordering of the original EmailAnalyticsView.compute* helpers.
    struct TallyAccumulator {
        private let calendar = Calendar.current

        private var total = 0
        private var sent = 0
        private var received = 0
        private var totalAttachments = 0
        private var storageBytes = 0

        private var timeline: [Date: (sent: Int, received: Int)] = [:]
        private var contacts: [String: Int] = [:]
        private var heatmap: [Int: [Int: Int]] = [:]
        private var attachmentTypes: [String: Int] = [:]
        private var domains: [String: Int] = [:]
        private var sizeBuckets: [String: Int] = [
            "< 1 KB": 0, "1-10 KB": 0, "10-100 KB": 0, "100 KB-1 MB": 0, "> 1 MB": 0
        ]
        private var relationships: [String: Int] = [:]

        private static let sizeOrder = ["< 1 KB", "1-10 KB", "10-100 KB", "100 KB-1 MB", "> 1 MB"]

        private func cleanAddress(_ raw: String) -> String {
            raw.components(separatedBy: "<").last?
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces).lowercased()
                ?? raw.trimmingCharacters(in: .whitespaces).lowercased()
        }

        mutating func ingest(_ email: MBOXParser.RawEmail) {
            total += 1
            if email.messageType == "sent" { sent += 1 }
            if email.messageType == "received" { received += 1 }

            // Attachments
            totalAttachments += email.attachments.count
            for att in email.attachments {
                let ext = (att.filename as NSString).pathExtension.lowercased()
                attachmentTypes[ext.isEmpty ? "unknown" : ext, default: 0] += 1
            }

            // Domains
            for domain in email.domains { domains[domain.lowercased(), default: 0] += 1 }

            // Size
            let size = email.rawSource.utf8.count
            storageBytes += size
            switch size {
            case ..<1024:            sizeBuckets["< 1 KB", default: 0] += 1
            case 1024..<10240:       sizeBuckets["1-10 KB", default: 0] += 1
            case 10240..<102400:     sizeBuckets["10-100 KB", default: 0] += 1
            case 102400..<1048576:   sizeBuckets["100 KB-1 MB", default: 0] += 1
            default:                 sizeBuckets["> 1 MB", default: 0] += 1
            }

            // Date-derived: timeline + heatmap
            if let date = MBOXParser.parseDate(email.headers["Date"]) {
                let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
                var entry = timeline[month, default: (sent: 0, received: 0)]
                if email.messageType == "sent" { entry.sent += 1 } else { entry.received += 1 }
                timeline[month] = entry

                let dow = calendar.component(.weekday, from: date) - 1
                let hour = (calendar.component(.hour, from: date) / 3) * 3
                heatmap[dow, default: [:]][hour, default: 0] += 1
            }

            // Top contacts
            let from = email.headers["From"] ?? ""
            if !from.isEmpty { contacts[cleanAddress(from), default: 0] += 1 }

            // Contact relationships (from ↔ each recipient)
            let fromKey = cleanAddress(from)
            if !fromKey.isEmpty {
                let recipients = (email.headers["To"] ?? "")
                    .components(separatedBy: ",")
                    .compactMap { addr -> String? in
                        let c = cleanAddress(addr)
                        return c.isEmpty ? nil : c
                    }
                for to in recipients {
                    let key = [fromKey, to].sorted().joined(separator: "↔")
                    relationships[key, default: 0] += 1
                }
            }
        }

        func finalize() -> AnalyticsData {
            var data = AnalyticsData()
            data.totalCount = total
            data.sentCount = sent
            data.receivedCount = received
            data.totalAttachments = totalAttachments
            data.totalStorageMB = Double(storageBytes) / (1024.0 * 1024.0)

            data.timelineBuckets = timeline.sorted { $0.key < $1.key }
                .map { TimelineBucket(date: $0.key, sent: $0.value.sent, received: $0.value.received) }

            data.topContacts = contacts.sorted { $0.value > $1.value }.prefix(10)
                .map { ContactCount(address: $0.key, count: $0.value) }

            var cells: [HeatmapCell] = []
            for day in 0..<7 {
                for h in stride(from: 0, to: 24, by: 3) {
                    cells.append(HeatmapCell(dayOfWeek: day, hour: h, count: heatmap[day]?[h] ?? 0))
                }
            }
            data.heatmapData = cells

            data.attachmentTypes = attachmentTypes.sorted { $0.value > $1.value }
                .map { AttachmentTypeCount(fileType: $0.key, count: $0.value) }

            data.domainCounts = domains.sorted { $0.value > $1.value }.prefix(15)
                .map { DomainCount(domain: $0.key, count: $0.value) }

            data.sizeDistribution = Self.sizeOrder.map { SizeBucket(label: $0, count: sizeBuckets[$0] ?? 0) }

            data.contactRelationships = relationships.sorted { $0.value > $1.value }.prefix(15)
                .map { pair -> ContactRelationship in
                    let parts = pair.key.components(separatedBy: "↔")
                    guard let from = parts.first else { return ContactRelationship(from: "?", to: "?", count: pair.value) }
                    return ContactRelationship(from: from, to: parts.count > 1 ? parts[1] : "?", count: pair.value)
                }

            return data
        }
    }
}
