//
//  ArchiveTimelineService.swift
//  maxmailin
//
//  Stage 5 W3 / Engine cutover 5 (v2-core-cutover): the bounded replacement for
//  EmailTimelineView's in-RAM `cachedParsedDates` (whole corpus).
//
//  Streams the scope once into per-DAY buckets (sent/received) + a 24-hour
//  histogram in the selected timezone — O(days) resident, regardless of archive
//  size. Week/month granularities re-aggregate the cached day buckets in memory
//  (no re-scan), and drill-down into a bucket is a bounded date-range query.
//
//  One shared `DayFold` backs both `load(days:timezone:)` (array oracle) and
//  `load(scope:timezone:)` (streaming), so the two are identical by construction.
//

import Foundation

struct TimelineData: Sendable {
    struct Day: Sendable {
        let day: Date          // startOfDay in the selected timezone
        var sent: Int
        var received: Int
        var total: Int { sent + received }
    }
    var days: [Day]            // ascending by day
    var hourCounts: [Int]      // 24 entries, in the selected timezone
    var totalEmails: Int
}

@MainActor
final class ArchiveTimelineService {

    static let shared = ArchiveTimelineService(service: .shared)

    private let service: ArchiveDataService
    init(service: ArchiveDataService) { self.service = service }

    /// Array path (oracle / legacy filtered selection).
    func load(days emails: [MBOXParser.RawEmail], timezone: TimeZone) async -> TimelineData {
        await Task.detached(priority: .userInitiated) {
            var fold = DayFold(timezone: timezone)
            for e in emails { fold.ingest(e) }
            return fold.finalize()
        }.value
    }

    /// Streaming path — one bounded pass into O(days) buckets.
    func load(scope query: EmailQuery = .all, timezone: TimeZone, batchSize: Int = 500) async throws -> TimelineData {
        let svc = service
        return try await Task.detached(priority: .userInitiated) {
            var fold = DayFold(timezone: timezone)
            let stream = await svc.streamFullEmails(query: query, batchSize: batchSize)
            for try await batch in stream {
                for e in batch { fold.ingest(e) }
            }
            return fold.finalize()
        }.value
    }

    /// Shared fold: per-day sent/received + hour histogram, timezone-aware.
    struct DayFold {
        private var calendar: Calendar
        private var dayMap: [Date: (sent: Int, received: Int)] = [:]
        private var hourCounts = [Int](repeating: 0, count: 24)
        private var total = 0

        init(timezone: TimeZone) {
            var cal = Calendar.current
            cal.timeZone = timezone
            self.calendar = cal
        }

        mutating func ingest(_ email: MBOXParser.RawEmail) {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { return }
            total += 1
            let day = calendar.startOfDay(for: date)
            var entry = dayMap[day] ?? (sent: 0, received: 0)
            if email.messageType == "sent" { entry.sent += 1 } else { entry.received += 1 }
            dayMap[day] = entry
            hourCounts[calendar.component(.hour, from: date)] += 1
        }

        func finalize() -> TimelineData {
            let days = dayMap.sorted { $0.key < $1.key }
                .map { TimelineData.Day(day: $0.key, sent: $0.value.sent, received: $0.value.received) }
            return TimelineData(days: days, hourCounts: hourCounts, totalEmails: total)
        }
    }
}
