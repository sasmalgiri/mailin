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
}
