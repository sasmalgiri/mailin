//
//  EmailTimelineView.swift
//  mailin
//
//  Interactive chronological timeline visualization of emails.
//

import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif

struct EmailTimelineView: View {
    /// nil → whole archive (streamed day buckets from SQLite, bounded);
    /// non-nil → a legacy filtered selection analyzed via the array path.
    var emails: [MBOXParser.RawEmail]? = nil
    var isPresented: Binding<Bool>?
    @State private var granularity: Granularity = .week
    @State private var selectedBucket: DateBucket?
    @State private var selectedTimezone: TimeZone = .current
    /// Bounded day buckets + hour histogram streamed from the store (O(days)).
    @State private var timelineData: TimelineData?
    /// Bounded drill-down emails for the selected bucket (date-range query, capped).
    @State private var drillEmails: [MBOXParser.RawEmail] = []
    @Environment(\.dismiss) private var envDismiss
    @State private var showTutorial = false

    // MARK: - Types

    enum Granularity: String, CaseIterable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
    }

    struct DateBucket: Identifiable, Equatable {
        let id: Date
        var sentCount: Int
        var receivedCount: Int
        var label: String

        static func == (lhs: DateBucket, rhs: DateBucket) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct HourActivity: Identifiable {
        let id: Int // hour 0-23
        var count: Int
        var maxCount: Int

        var opacity: Double {
            guard maxCount > 0 else { return 0.05 }
            return max(0.05, Double(count) / Double(maxCount))
        }
    }

    // MARK: - Computed Data

    private func loadTimeline() async {
        let tz = selectedTimezone
        if let emails {
            timelineData = await ArchiveTimelineService.shared.load(days: emails, timezone: tz)
        } else {
            timelineData = try? await ArchiveTimelineService.shared.load(scope: .all, timezone: tz)
        }
    }

    private var normalizedCalendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = selectedTimezone
        return cal
    }

    private var buckets: [DateBucket] {
        let calendar = normalizedCalendar
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.timeZone = selectedTimezone

        var grouped: [Date: (sent: Int, received: Int)] = [:]

        for day in timelineData?.days ?? [] {
            let bucketDate: Date
            switch granularity {
            case .day:
                bucketDate = day.day   // already startOfDay in this timezone
            case .week:
                let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day.day)
                bucketDate = calendar.date(from: components) ?? day.day
            case .month:
                let components = calendar.dateComponents([.year, .month], from: day.day)
                bucketDate = calendar.date(from: components) ?? day.day
            }

            var entry = grouped[bucketDate] ?? (sent: 0, received: 0)
            entry.sent += day.sent
            entry.received += day.received
            grouped[bucketDate] = entry
        }

        return grouped.map { key, value in
            let label: String
            switch granularity {
            case .day:
                dateFormatter.dateFormat = "MMM d, yyyy"
                label = dateFormatter.string(from: key)
            case .week:
                dateFormatter.dateFormat = "MMM d"
                let endOfWeek = calendar.date(byAdding: .day, value: 6, to: key) ?? key
                label = "\(dateFormatter.string(from: key)) - \(dateFormatter.string(from: endOfWeek))"
            case .month:
                dateFormatter.dateFormat = "MMM yyyy"
                label = dateFormatter.string(from: key)
            }
            return DateBucket(id: key, sentCount: value.sent, receivedCount: value.received, label: label)
        }
        .sorted { $0.id < $1.id }
    }

    private var hourDistribution: [HourActivity] {
        let hourCounts = timelineData?.hourCounts ?? [Int](repeating: 0, count: 24)
        let maxCount = hourCounts.max() ?? 1
        return (0..<24).map { hour in
            HourActivity(id: hour, count: hourCounts[hour], maxCount: maxCount)
        }
    }

    private var stats: TimelineStats {
        let calendar = normalizedCalendar
        // Derived from the bounded day buckets (each already a startOfDay in tz).
        let days = timelineData?.days ?? []
        let totalEmails = timelineData?.totalEmails ?? 0
        guard !days.isEmpty else {
            return TimelineStats(
                busiestDay: "N/A",
                busiestDayCount: 0,
                avgEmailsPerDay: 0,
                longestGap: "None",
                totalDays: 0,
                totalEmails: 0
            )
        }

        // Busiest day
        let busiest = days.max { $0.total < $1.total }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"
        let busiestDayStr = busiest.map { dateFormatter.string(from: $0.day) } ?? "N/A"

        // Average emails per day (span of observed days)
        let firstDate = days.first?.day ?? Date()
        let lastDate = days.last?.day ?? Date()
        let daySpan = max(1, calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 1)
        let avgPerDay = Double(totalEmails) / Double(daySpan)

        // Longest gap between consecutive present days
        let sortedDays = days.map(\.day)
        var longestGapDays = 0
        for i in 1..<max(1, sortedDays.count) {
            let gap = calendar.dateComponents([.day], from: sortedDays[i - 1], to: sortedDays[i]).day ?? 0
            longestGapDays = max(longestGapDays, gap)
        }
        let gapStr: String
        if longestGapDays == 0 {
            gapStr = "None"
        } else if longestGapDays < 7 {
            gapStr = "\(longestGapDays) day\(longestGapDays == 1 ? "" : "s")"
        } else {
            let weeks = longestGapDays / 7
            let remainDays = longestGapDays % 7
            gapStr = remainDays > 0 ? "\(weeks)w \(remainDays)d" : "\(weeks) week\(weeks == 1 ? "" : "s")"
        }

        return TimelineStats(
            busiestDay: busiestDayStr,
            busiestDayCount: busiest?.total ?? 0,
            avgEmailsPerDay: avgPerDay,
            longestGap: gapStr,
            totalDays: daySpan,
            totalEmails: totalEmails
        )
    }

    struct TimelineStats {
        let busiestDay: String
        let busiestDayCount: Int
        let avgEmailsPerDay: Double
        let longestGap: String
        let totalDays: Int
        let totalEmails: Int
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if (timelineData?.totalEmails ?? 0) == 0 {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: Spacing.large) {
                        granularityPicker
                        chartSection
                        heatmapSection
                        statsSection
                        if let selectedBucket {
                            selectedBucketSection(bucket: selectedBucket)
                        }
                    }
                    .padding(Spacing.large)
                }
            }
        }
        .onChange(of: selectedDate) { _, _ in syncSelection() }
        .task { await loadTimeline() }
        .onChange(of: selectedTimezone) { _, _ in Task { await loadTimeline() } }
        .onChange(of: selectedBucket) { _, bucket in Task { await loadDrill(for: bucket) } }
        .featureTutorial(.emailTimeline, key: "email_timeline_tutorial_seen", isPresented: $showTutorial)
        #if os(macOS)
        .toolWindowFrame()
        #endif
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("Email Timeline")
                    .font(Typography.title3)
                Text("\(timelineData?.totalEmails ?? 0) emails analyzed")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            TutorialHelpButton(showTutorial: $showTutorial)
            SaveToDocumentsButton(title: "Timeline") {
                [.init(key: "Emails analyzed", value: "\(timelineData?.totalEmails ?? 0)")]
            }
            if isPresented != nil {
                Button("Done") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.medium)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView(
                icon: "calendar.badge.clock",
                title: "No Timeline Data",
                message: "Import emails to see the chronological timeline."
            )
            Spacer()
        }
    }

    // MARK: - Granularity Picker

    private static let commonTimezones: [(label: String, tz: TimeZone)] = {
        let ids = ["UTC", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
                    "Europe/London", "Europe/Paris", "Europe/Berlin", "Asia/Tokyo", "Asia/Shanghai",
                    "Asia/Kolkata", "Australia/Sydney", "Pacific/Auckland"]
        return ids.compactMap { id -> (String, TimeZone)? in
            guard let tz = TimeZone(identifier: id) else { return nil }
            let abbr = tz.abbreviation() ?? id
            return ("\(abbr) — \(id.replacingOccurrences(of: "_", with: " ").components(separatedBy: "/").last ?? id)", tz)
        }
    }()

    private var granularityPicker: some View {
        HStack {
            Text("Group by:")
                .font(Typography.subheadline)
                .foregroundColor(AppColors.secondary)
            Picker("Granularity", selection: $granularity) {
                ForEach(Granularity.allCases, id: \.self) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .accessibilityLabel("Timeline granularity")
            Spacer()
            Text("Timezone:")
                .font(Typography.subheadline)
                .foregroundColor(AppColors.secondary)
            Picker("Timezone", selection: $selectedTimezone) {
                Text("Local (\(TimeZone.current.abbreviation() ?? ""))").tag(TimeZone.current)
                Divider()
                ForEach(Self.commonTimezones, id: \.tz.identifier) { item in
                    Text(item.label).tag(item.tz)
                }
            }
            .frame(maxWidth: 220)
            .accessibilityLabel("Normalize timestamps to timezone")
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Email Volume Over Time")
                .font(Typography.headline)

            chartLegend

            ScrollView(.horizontal, showsIndicators: true) {
                Chart {
                    ForEach(buckets) { bucket in
                        BarMark(
                            x: .value("Period", bucket.id, unit: chartUnit),
                            y: .value("Sent", bucket.sentCount)
                        )
                        .foregroundStyle(AppColors.sentEmail)
                        .accessibilityLabel("Sent: \(bucket.sentCount) in \(bucket.label)")

                        BarMark(
                            x: .value("Period", bucket.id, unit: chartUnit),
                            y: .value("Received", bucket.receivedCount)
                        )
                        .foregroundStyle(AppColors.receivedEmail)
                        .accessibilityLabel("Received: \(bucket.receivedCount) in \(bucket.label)")
                    }

                    if let selectedBucket {
                        RuleMark(x: .value("Selected", selectedBucket.id, unit: chartUnit))
                            .foregroundStyle(Color.primary.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxisLabel("Emails")
                .frame(
                    width: max(CGFloat(buckets.count) * chartBarWidth, 400),
                    height: 220
                )
                .accessibilityLabel("Email volume bar chart grouped by \(granularity.rawValue)")
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    @State private var selectedDate: Date?

    private var chartUnit: Calendar.Component {
        switch granularity {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var chartBarWidth: CGFloat {
        switch granularity {
        case .day: return 30
        case .week: return 50
        case .month: return 60
        }
    }

    private var chartLegend: some View {
        HStack(spacing: Spacing.medium) {
            HStack(spacing: Spacing.xxSmall) {
                Circle().fill(AppColors.sentEmail).frame(width: 10, height: 10)
                Text("Sent").font(Typography.caption1)
            }
            HStack(spacing: Spacing.xxSmall) {
                Circle().fill(AppColors.receivedEmail).frame(width: 10, height: 10)
                Text("Received").font(Typography.caption1)
            }
        }
    }

    // MARK: - Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Hour-of-Day Activity")
                .font(Typography.headline)
            Text("Darker cells indicate more email activity at that hour.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            let hours = hourDistribution
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 12)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(hours) { hour in
                    VStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .fill(AppColors.sentEmail.opacity(hour.opacity))
                            .frame(height: 28)
                            .overlay(
                                Text("\(hour.count)")
                                    .font(Typography.caption2)
                                    .foregroundColor(hour.opacity > 0.5 ? .white : .primary)
                            )
                        Text(hourLabel(hour.id))
                            .font(.system(size: 9))
                            .foregroundColor(AppColors.secondary)
                    }
                    .accessibilityLabel("\(hourLabel(hour.id)): \(hour.count) emails")
                }
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Key Statistics")
                .font(Typography.headline)

            let s = stats
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.small) {
                statCard(title: "Busiest Day", value: s.busiestDay, detail: "\(s.busiestDayCount) emails")
                statCard(title: "Avg Emails/Day", value: String(format: "%.1f", s.avgEmailsPerDay), detail: "over \(s.totalDays) days")
                statCard(title: "Longest Gap", value: s.longestGap, detail: "without emails")
                statCard(title: "Total Emails", value: "\(s.totalEmails)", detail: "with valid dates")
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    private func statCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text(title)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Text(value)
                .font(Typography.title3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.small)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value), \(detail)")
    }

    // MARK: - Selected Bucket Detail

    private func selectedBucketSection(bucket: DateBucket) -> some View {
        let bucketEmails = drillEmails

        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("Emails: \(bucket.label)")
                    .font(Typography.headline)
                Spacer()
                Button {
                    selectedBucket = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close email list")
            }

            Text("\(bucket.sentCount) sent, \(bucket.receivedCount) received")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            Divider()

            ForEach(bucketEmails.prefix(50)) { email in
                HStack(spacing: Spacing.small) {
                    Circle()
                        .fill(email.messageType == "sent" ? AppColors.sentEmail : AppColors.receivedEmail)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(email.headers["Subject"] ?? "(No Subject)")
                            .font(Typography.callout)
                            .lineLimit(1)
                        Text(email.headers["From"] ?? "")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(email.timestamp.prefix(10))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(.vertical, Spacing.xxxSmall)
            }

            if bucketEmails.count > 50 {
                Text("... and \(bucketEmails.count - 50) more")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.large)
    }

    // MARK: - Selection Sync

    private func syncSelection() {
        guard let selectedDate else {
            selectedBucket = nil
            return
        }
        // Find the bucket closest to the selected date
        selectedBucket = buckets.min(by: {
            abs($0.id.timeIntervalSince(selectedDate)) < abs($1.id.timeIntervalSince(selectedDate))
        })
    }

    /// Bounded drill-down: fetch (up to 50) full emails in the selected bucket's
    /// date range instead of holding the corpus. For a legacy injected selection
    /// the range filter is applied in-memory over that (already bounded) array.
    private func loadDrill(for bucket: DateBucket?) async {
        guard let bucket else { drillEmails = []; return }
        let cal = normalizedCalendar
        let end: Date
        switch granularity {
        case .day:   end = cal.date(byAdding: .day, value: 1, to: bucket.id) ?? bucket.id
        case .week:  end = cal.date(byAdding: .day, value: 7, to: bucket.id) ?? bucket.id
        case .month: end = cal.date(byAdding: .month, value: 1, to: bucket.id) ?? bucket.id
        }
        let start = bucket.id
        if let emails {
            drillEmails = Array(emails.filter {
                guard let d = MBOXParser.parseDate($0.headers["Date"]) else { return false }
                return d >= start && d < end
            }.prefix(50))
        } else {
            var q = EmailQuery.all
            q.afterDate = start.addingTimeInterval(-1)
            q.beforeDate = end
            var collected: [MBOXParser.RawEmail] = []
            let stream = ArchiveDataService.shared.streamFullEmails(query: q, batchSize: 50)
            do {
                for try await batch in stream {
                    collected.append(contentsOf: batch)
                    if collected.count >= 50 { break }
                }
            } catch { }
            drillEmails = Array(collected.prefix(50))
        }
    }
}

