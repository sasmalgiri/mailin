//
//  DigestScheduler.swift
//  maxmailin
//
//  Weekly digest notification: "N new emails matched your saved searches."
//  Fully offline and minimum-touch — computed from the archive's saved
//  searches via exact repository counts (afterDate = last digest), delivered
//  as one local notification at most once per week, checked at launch.
//  Opt-in via Settings ▸ Notifications ▸ Weekly Digest.
//

import Foundation
import UserNotifications
import os.log

@MainActor
final class DigestScheduler {

    static let shared = DigestScheduler()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "Digest")

    static let enabledKey = "weeklyDigestEnabled"
    static let lastDigestKey = "mailin.digest.lastDelivered"

    /// Test seams.
    static var testDefaultsOverride: UserDefaults?
    private var defaults: UserDefaults { Self.testDefaultsOverride ?? .standard }

    struct DigestLine: Sendable, Equatable {
        let searchName: String
        let newMatches: Int
    }

    /// Launch hook: at most one digest per 7 days; a no-op when disabled,
    /// when no saved searches exist, or when nothing new matched.
    func checkAndDeliver() {
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        let last = defaults.object(forKey: Self.lastDigestKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 7 * 24 * 3600 else { return }
        Task { @MainActor in
            let lines = await computeDigest(since: max(last, Date().addingTimeInterval(-14 * 24 * 3600)))
            let total = lines.reduce(0) { $0 + $1.newMatches }
            // Stamp even on empty results — "nothing new" shouldn't re-check
            // every launch for a week.
            defaults.set(Date(), forKey: Self.lastDigestKey)
            guard total > 0 else { return }
            deliver(lines: lines, total: total)
        }
    }

    /// Exact per-saved-search counts of emails dated after `since` —
    /// repository aggregates, never materialized results.
    func computeDigest(since: Date) async -> [DigestLine] {
        guard let data = UserDefaults.standard.data(forKey: "mailin_savedSearches"),
              let searches = try? JSONDecoder().decode([ParsedEmailListViewModel.SavedSearch].self, from: data),
              !searches.isEmpty else { return [] }
        var lines: [DigestLine] = []
        for search in searches.prefix(20) {   // bounded: 20 searches per digest
            var query = ArchiveQueryCompiler.compile(search.query)
            query.afterDate = max(query.afterDate ?? .distantPast, since)
            let count = (try? await ArchiveDataService.shared.count(query: query)) ?? 0
            if count > 0 { lines.append(DigestLine(searchName: search.name, newMatches: count)) }
        }
        return lines
    }

    private func deliver(lines: [DigestLine], total: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Your weekly mailin digest"
        content.body = lines.prefix(4)
            .map { "\($0.newMatches) new for “\($0.searchName)”" }
            .joined(separator: " · ")
            + (lines.count > 4 ? " · +\(lines.count - 4) more" : "")
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "mailin.weeklyDigest",
            content: content,
            trigger: nil   // deliver now (the weekly cadence is the launch gate)
        )
        UNUserNotificationCenter.current().add(request)
        Self.logger.info("weekly digest delivered: \(total) new match(es) across \(lines.count) search(es)")
    }
}
