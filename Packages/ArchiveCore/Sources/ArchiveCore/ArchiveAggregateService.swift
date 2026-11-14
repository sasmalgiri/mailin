//
//  ArchiveAggregateService.swift
//  maxmailin
//
//  Stage 5 Wave 2A (v2-core-cutover): DB-side aggregates. Metadata, widget and
//  analytics counts come from SQL (`COUNT`, `MIN/MAX`, `GROUP BY`) over the
//  SQLite store — never by streaming millions of full bodies to count metadata.
//  This is the shared authority that replaces whole-corpus `[RawEmail]` scans in
//  the metadata / widget / analytics consumers.
//

import Foundation

struct AggregateBucket: Sendable, Identifiable, Equatable {
    let value: String
    let count: Int
    var id: String { value }
}

struct ArchiveAggregates: Sendable, Equatable {
    var total: Int
    var withAttachments: Int
    var minDate: Date?
    var maxDate: Date?
    var topSenders: [AggregateBucket]
    var topSubjects: [AggregateBucket]
}

@MainActor
final class ArchiveAggregateService {
    static let shared = ArchiveAggregateService(store: .shared)

    private let store: SQLiteEmailStore
    init(store: SQLiteEmailStore) { self.store = store }

    /// Total email count (DB aggregate).
    func total() async throws -> Int { try await store.totalCount() }

    /// A bounded snapshot of headline aggregates for dashboards / widgets.
    func snapshot(topLimit: Int = 10) async throws -> ArchiveAggregates {
        let total = try await store.totalCount()
        let range = try await store.dateRangeSeconds()
        let attachments = try await store.attachmentCount()
        let senders = try await store.topGrouped(.fromAddr, limit: topLimit)
        let subjects = try await store.topGrouped(.subject, limit: topLimit)
        return ArchiveAggregates(
            total: total,
            withAttachments: attachments,
            minDate: range.min.map { Date(timeIntervalSince1970: Double($0)) },
            maxDate: range.max.map { Date(timeIntervalSince1970: Double($0)) },
            topSenders: senders,
            topSubjects: subjects
        )
    }

    func topSenders(limit: Int = 10) async throws -> [AggregateBucket] {
        try await store.topGrouped(.fromAddr, limit: limit)
    }
    func topSubjects(limit: Int = 10) async throws -> [AggregateBucket] {
        try await store.topGrouped(.subject, limit: limit)
    }

    // MARK: - Part G aggregates (replace preview-array walks in legacy screens)

    /// Total archive size in bytes (SUM(size_bytes) — DB aggregate).
    func totalSizeBytes() async throws -> Int {
        try await store.totalSizeBytes()
    }

    /// Per-sender rollups (count / bytes / latest date) for the cleanup view —
    /// a bounded GROUP BY, never a corpus scan.
    func senderRollups(limit: Int = 200) async throws -> [SQLiteEmailStore.SenderRollup] {
        try await store.senderRollups(limit: limit)
    }

    /// Sent/received split using the same rule the legacy annotator applied
    /// (From contains the user's address ⇒ sent), as two COUNT aggregates.
    func sentReceivedCounts(senderEmail: String) async throws -> (sent: Int, received: Int) {
        let needle = senderEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let total = try await store.totalCount()
        guard !needle.isEmpty else { return (0, total) }
        let sent = try await store.countFromContains(needle)
        return (sent, max(0, total - sent))
    }

    /// Reply frequency: recipient → number of emails the user (From contains
    /// `senderEmail`) sent them. DB GROUP BY over the To field, bounded by
    /// `fieldLimit` distinct To strings; multi-recipient fields are split
    /// client-side exactly like the legacy array walk.
    func replyRecipientCounts(senderEmail: String, fieldLimit: Int = 500) async throws -> [String: Int] {
        let needle = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }
        let buckets = try await store.recipientFieldCounts(senderContains: needle, limit: fieldLimit)
        var counts: [String: Int] = [:]
        for bucket in buckets {
            let recipients = bucket.value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            for recipient in recipients where !recipient.isEmpty {
                counts[recipient, default: 0] += bucket.count
            }
        }
        return counts
    }
}
