//
//  ArchiveAnalyticsService.swift
//  maxmailin
//
//  Stage 5 W2-C / Phase 7 (v2-core-cutover): the bounded analytics snapshot the
//  analytics UI consumes instead of an in-RAM `[RawEmail]` corpus. Every figure
//  is a DB aggregate (COUNT / MIN-MAX / GROUP BY) — total, attachments, date
//  range, top senders/subjects, and per-month volume — so opening the analytics
//  sheet never scans or retains the archive.
//

import Foundation

struct ArchiveAnalyticsSnapshot: Sendable, Equatable {
    var total: Int
    var withAttachments: Int
    var minDate: Date?
    var maxDate: Date?
    var topSenders: [AggregateBucket]
    var topSubjects: [AggregateBucket]
    /// "YYYY-MM" → count, ascending by month.
    var monthlyVolume: [AggregateBucket]
}

@MainActor
final class ArchiveAnalyticsService {
    static let shared = ArchiveAnalyticsService(store: .shared)

    private let store: SQLiteEmailStore
    private let aggregates: ArchiveAggregateService
    init(store: SQLiteEmailStore) {
        self.store = store
        self.aggregates = ArchiveAggregateService(store: store)
    }

    func snapshot(topLimit: Int = 10) async throws -> ArchiveAnalyticsSnapshot {
        let agg = try await aggregates.snapshot(topLimit: topLimit)
        let monthly = try await store.monthlyCounts()
        return ArchiveAnalyticsSnapshot(
            total: agg.total,
            withAttachments: agg.withAttachments,
            minDate: agg.minDate,
            maxDate: agg.maxDate,
            topSenders: agg.topSenders,
            topSubjects: agg.topSubjects,
            monthlyVolume: monthly
        )
    }
}
