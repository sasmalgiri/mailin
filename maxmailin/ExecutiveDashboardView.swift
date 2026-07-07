//
//  ExecutiveDashboardView.swift
//  mailin
//
//  Real-time KPI dashboard showing at-a-glance email archive metrics.
//

import SwiftUI
import Charts
import NaturalLanguage

struct ExecutiveDashboardView: View {
    let emails: [MBOXParser.RawEmail]
    var v2Source: PaginatedEmailViewModel? = nil

    private var effectiveEmails: [MBOXParser.RawEmail] {
        if let v2 = v2Source, !v2.emails.isEmpty { return v2.emails }
        return emails
    }
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var dashboardData: DashboardData?
    @State private var isComputing = false
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @State private var showTutorial = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isComputing {
                VStack {
                    Spacer()
                    ProgressView("Computing dashboard metrics...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if let data = dashboardData {
                ScrollView {
                    VStack(spacing: Spacing.large) {
                        topStatCards(data: data)
                        aiInsightsSection(data: data)
                        middleCharts(data: data)
                        bottomSection(data: data)
                    }
                    .padding(Spacing.large)
                }
            } else {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "gauge.open.with.lines.needle.33percent",
                        title: "No Data",
                        message: "Import an email archive to view the executive dashboard."
                    )
                    Spacer()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
        .background(AppColors.backgroundTertiary)
        .featureTutorial(.executiveDashboard, key: "executive_dashboard_tutorial_seen", isPresented: $showTutorial)
        .task { await computeDashboard() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .font(.title2)
                    .adaptiveIconGradient(colors: [.blue, .purple])
                VStack(alignment: .leading, spacing: 2) {
                    Text("Executive Dashboard")
                        .font(Typography.headline)
                    Text("\(emails.count) emails")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            Spacer()
            TutorialHelpButton(showTutorial: $showTutorial)
            if isPresented != nil {
                Button("Done") { closeSheet() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    // MARK: - Top Stat Cards

    private var dashboardStatColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.flexible()), GridItem(.flexible())]
        #else
        [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        #endif
    }

    private func topStatCards(data: DashboardData) -> some View {
        LazyVGrid(columns: dashboardStatColumns, spacing: Spacing.small) {
            AnimatedStatCard(
                title: "Total Emails",
                value: "\(data.totalEmails)",
                icon: "envelope.fill",
                color: .blue
            )
            AnimatedStatCard(
                title: "Unique Contacts",
                value: "\(data.uniqueContacts)",
                icon: "person.2.fill",
                color: .green
            )
            AnimatedStatCard(
                title: "Avg Sentiment",
                value: String(format: "%.2f", data.averageSentiment),
                icon: "heart.fill",
                color: data.averageSentiment > 0.4 ? .green : (data.averageSentiment < -0.4 ? .red : .orange)
            )
            AnimatedStatCard(
                title: "Response Rate",
                value: String(format: "%.0f%%", data.responseRate * 100),
                icon: "arrowshape.turn.up.left.fill",
                color: .orange
            )
        }
    }

    // MARK: - Middle Charts

    private func middleCharts(data: DashboardData) -> some View {
        #if os(iOS)
        VStack(spacing: Spacing.medium) {
            volumeTrendChart(data: data)
            sentimentTrendChart(data: data)
        }
        #else
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.medium) {
            volumeTrendChart(data: data)
            sentimentTrendChart(data: data)
        }
        #endif
    }

    private func volumeTrendChart(data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Volume Trend (12 Weeks)", systemImage: "chart.bar.fill")
                .font(Typography.headline)

            if data.weeklyVolume.isEmpty {
                Text("Not enough data for weekly trends.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .frame(height: 200)
            } else {
                Chart(data.weeklyVolume) { bucket in
                    BarMark(
                        x: .value("Week", bucket.weekLabel),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue, .blue.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(CornerRadius.small)
                }
                .chartYAxisLabel("Emails")
                .frame(height: 200)
            }
        }
        .cardStyle()
    }

    private func sentimentTrendChart(data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Sentiment Trend", systemImage: "heart.text.square")
                .font(Typography.headline)

            if data.weeklySentiment.isEmpty {
                Text("Not enough data for sentiment trends.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .frame(height: 200)
            } else {
                Chart(data.weeklySentiment) { bucket in
                    LineMark(
                        x: .value("Week", bucket.weekLabel),
                        y: .value("Sentiment", bucket.averageSentiment)
                    )
                    .foregroundStyle(.purple)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Week", bucket.weekLabel),
                        y: .value("Sentiment", bucket.averageSentiment)
                    )
                    .foregroundStyle(.purple)
                    .symbolSize(30)
                }
                .chartYAxisLabel("Score")
                .frame(height: 200)
            }
        }
        .cardStyle()
    }

    // MARK: - AI Insights

    private func aiInsightsSection(data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Label("AI-Enhanced Analysis", systemImage: "sparkles")
                    .font(Typography.headline)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                } else if aiInsights == nil {
                    Button {
                        loadAIInsights(data: data)
                    } label: {
                        Label("Enhance with AI", systemImage: "sparkles")
                            .font(Typography.caption1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
            }

            if let insights = aiInsights {
                Text(insights)
                    .font(Typography.body)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            } else if !isLoadingAI {
                Text("Tap Enhance with AI for executive-level insights beyond the KPI metrics.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundPrimary)
        .cornerRadius(CornerRadius.large)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func loadAIInsights(data: DashboardData) {
        isLoadingAI = true
        let context = """
        Executive dashboard: \(data.totalEmails) emails, \(data.uniqueContacts) contacts, \
        avg sentiment \(String(format: "%.2f", data.averageSentiment)), \
        response rate \(String(format: "%.0f%%", data.responseRate * 100)).
        """
        let emailsCopy = emails
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .all,
                    emails: emailsCopy,
                    context: context
                )
                aiInsights = result ?? "AI analysis unavailable."
            } else {
                aiInsights = "Requires macOS 26 or later."
            }
            #else
            aiInsights = "AI features not available on this platform."
            #endif
            isLoadingAI = false
        }
    }

    // MARK: - Bottom Section

    private func bottomSection(data: DashboardData) -> some View {
        #if os(iOS)
        VStack(spacing: Spacing.medium) {
            topContactsChart(data: data)
            categoryDistributionChart(data: data)
            recentActivityFeed(data: data)
        }
        #else
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.medium) {
            topContactsChart(data: data)
            categoryDistributionChart(data: data)
            recentActivityFeed(data: data)
        }
        #endif
    }

    private func topContactsChart(data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Top 5 Contacts", systemImage: "person.crop.circle")
                .font(Typography.headline)

            if data.topContacts.isEmpty {
                Text("No contact data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart(data.topContacts) { contact in
                    BarMark(
                        x: .value("Count", contact.count),
                        y: .value("Contact", contact.name)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.green, .teal],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(CornerRadius.small)
                }
                .chartXAxisLabel("Emails")
                .frame(height: 180)
            }
        }
        .cardStyle()
    }

    private func categoryDistributionChart(data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Category Distribution", systemImage: "chart.pie.fill")
                .font(Typography.headline)

            if data.categoryDistribution.isEmpty {
                Text("No category data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart(data.categoryDistribution) { category in
                    BarMark(
                        x: .value("Category", category.name),
                        y: .value("Count", category.count)
                    )
                    .foregroundStyle(by: .value("Category", category.name))
                    .cornerRadius(CornerRadius.small)
                }
                .chartLegend(.hidden)
                .chartYAxisLabel("Emails")
                .frame(height: 180)
            }
        }
        .cardStyle()
    }

    private func recentActivityFeed(data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                .font(Typography.headline)

            if data.recentEmails.isEmpty {
                Text("No recent emails.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                VStack(spacing: Spacing.xxSmall) {
                    ForEach(data.recentEmails) { item in
                        HStack(spacing: Spacing.xSmall) {
                            ContactAvatar(name: item.from, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.from)
                                    .font(Typography.caption1)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Text(item.subject)
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(item.timeAgo)
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                        .padding(.vertical, Spacing.xxxSmall)
                        if item.id != data.recentEmails.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Computation

    private func computeDashboard() async {
        guard !emails.isEmpty else { return }
        isComputing = true

        let emailsCopy = emails
        let result = await Task.detached { () -> DashboardData in
            return Self.buildDashboardData(from: emailsCopy)
        }.value

        await MainActor.run {
            dashboardData = result
            isComputing = false
        }
    }

    nonisolated private static func buildDashboardData(from emails: [MBOXParser.RawEmail]) -> DashboardData {
        let totalEmails = emails.count

        // Unique contacts
        var contactSet = Set<String>()
        for email in emails {
            if let from = email.headers["From"] {
                contactSet.insert(extractAddress(from: from).lowercased())
            }
            if let to = email.headers["To"] {
                for addr in to.components(separatedBy: ",") {
                    let a = extractAddress(from: addr).lowercased()
                    if !a.isEmpty { contactSet.insert(a) }
                }
            }
        }
        let uniqueContacts = contactSet.count

        // Sentiment
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var totalSentiment = 0.0
        var sentimentCount = 0
        for email in emails {
            let text = bodyText(for: email)
            guard !text.isEmpty else { continue }
            tagger.string = text
            let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
            if let raw = tag?.rawValue, let score = Double(raw) {
                totalSentiment += score
                sentimentCount += 1
            }
        }
        let averageSentiment = sentimentCount > 0 ? totalSentiment / Double(sentimentCount) : 0.0

        // Response rate: emails that are replies / total
        let replyCount = emails.filter { email in
            let subject = (email.headers["Subject"] ?? "").lowercased()
            return subject.hasPrefix("re:") || email.inReplyTo != nil
        }.count
        let responseRate = totalEmails > 0 ? Double(replyCount) / Double(totalEmails) : 0.0

        // Parse dates
        struct DatedEmail {
            let email: MBOXParser.RawEmail
            let date: Date
        }
        let datedEmails: [DatedEmail] = emails.compactMap { email in
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { return nil }
            return DatedEmail(email: email, date: date)
        }.sorted { $0.date < $1.date }

        // Weekly volume (last 12 weeks)
        let calendar = Calendar.current
        let now = datedEmails.last?.date ?? Date()
        var weeklyVolume: [WeeklyVolumeBucket] = []
        for i in (0..<12).reversed() {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -i, to: now) else { continue }
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart
            let count = datedEmails.filter { $0.date >= weekStart && $0.date < weekEnd }.count
            let label = weekLabel(for: weekStart, calendar: calendar)
            weeklyVolume.append(WeeklyVolumeBucket(weekLabel: label, count: count))
        }

        // Weekly sentiment
        var weeklySentiment: [WeeklySentimentBucket] = []
        for i in (0..<12).reversed() {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -i, to: now) else { continue }
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart
            let weekEmails = datedEmails.filter { $0.date >= weekStart && $0.date < weekEnd }
            var weekSentTotal = 0.0
            var weekSentCount = 0
            for de in weekEmails {
                let text = bodyText(for: de.email)
                guard !text.isEmpty else { continue }
                tagger.string = text
                let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
                if let raw = tag?.rawValue, let score = Double(raw) {
                    weekSentTotal += score
                    weekSentCount += 1
                }
            }
            let avg = weekSentCount > 0 ? weekSentTotal / Double(weekSentCount) : 0.0
            let label = weekLabel(for: weekStart, calendar: calendar)
            weeklySentiment.append(WeeklySentimentBucket(weekLabel: label, averageSentiment: avg))
        }

        // Top 5 contacts by email count
        var contactCounts: [String: Int] = [:]
        for email in emails {
            if let from = email.headers["From"] {
                let name = extractDisplayName(from: from)
                contactCounts[name, default: 0] += 1
            }
        }
        let topContacts = contactCounts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { TopContact(name: $0.key, count: $0.value) }

        // Category distribution (by messageType)
        var categoryCounts: [String: Int] = [:]
        for email in emails {
            let cat = email.messageType.isEmpty ? "Unknown" : email.messageType.capitalized
            categoryCounts[cat, default: 0] += 1
        }
        let categoryDistribution = categoryCounts.sorted { $0.value > $1.value }
            .map { CategoryBucket(name: $0.key, count: $0.value) }

        // Recent 10 emails
        let recentEmails = datedEmails.suffix(10).reversed().map { de -> RecentEmailItem in
            let from = extractDisplayName(from: de.email.headers["From"] ?? "Unknown")
            let subject = de.email.headers["Subject"] ?? "(No Subject)"
            let timeAgo = Self.timeAgoString(from: de.date)
            return RecentEmailItem(from: from, subject: subject, timeAgo: timeAgo)
        }

        return DashboardData(
            totalEmails: totalEmails,
            uniqueContacts: uniqueContacts,
            averageSentiment: averageSentiment,
            responseRate: responseRate,
            weeklyVolume: weeklyVolume,
            weeklySentiment: weeklySentiment,
            topContacts: Array(topContacts),
            categoryDistribution: categoryDistribution,
            recentEmails: Array(recentEmails)
        )
    }

    // MARK: - Helpers

    nonisolated private static func bodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    nonisolated private static func extractAddress(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.range(of: "<"), let close = trimmed.range(of: ">") {
            return String(trimmed[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.contains("@") { return trimmed }
        return ""
    }

    nonisolated private static func extractDisplayName(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.range(of: "<") {
            let name = trimmed[trimmed.startIndex..<open.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return extractAddress(from: trimmed)
    }

    nonisolated private static func weekLabel(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    nonisolated private static func timeAgoString(from date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "1 day ago" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        if months == 1 { return "1 month ago" }
        return "\(months) months ago"
    }
}

// MARK: - Data Models

private struct DashboardData {
    let totalEmails: Int
    let uniqueContacts: Int
    let averageSentiment: Double
    let responseRate: Double
    let weeklyVolume: [WeeklyVolumeBucket]
    let weeklySentiment: [WeeklySentimentBucket]
    let topContacts: [TopContact]
    let categoryDistribution: [CategoryBucket]
    let recentEmails: [RecentEmailItem]
}

private struct WeeklyVolumeBucket: Identifiable {
    let id = UUID()
    let weekLabel: String
    let count: Int
}

private struct WeeklySentimentBucket: Identifiable {
    let id = UUID()
    let weekLabel: String
    let averageSentiment: Double
}

private struct TopContact: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
}

private struct CategoryBucket: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
}

private struct RecentEmailItem: Identifiable {
    let id = UUID()
    let from: String
    let subject: String
    let timeAgo: String
}
