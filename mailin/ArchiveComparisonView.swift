import SwiftUI

struct ArchiveComparisonView: View {
    let archiveA: [MBOXParser.RawEmail]
    let archiveB: [MBOXParser.RawEmail]
    let nameA: String
    let nameB: String
    @State private var filter: ComparisonFilter = .all
    @State private var comparisonResult: ComparisonResult?
    @State private var isComputing = false
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @Environment(\.dismiss) private var dismiss

    enum ComparisonFilter: String, CaseIterable {
        case all = "All"
        case onlyInA = "Only in A"
        case onlyInB = "Only in B"
        case common = "Common"
    }

    struct ComparisonResult {
        var onlyInA: [MBOXParser.RawEmail]
        var onlyInB: [MBOXParser.RawEmail]
        var common: [(MBOXParser.RawEmail, MBOXParser.RawEmail)]
        var statsA: ArchiveStats
        var statsB: ArchiveStats
    }

    struct ArchiveStats {
        var totalCount: Int
        var dateRange: String
        var uniqueSenders: Int
        var avgSentiment: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isComputing {
                VStack(spacing: Spacing.medium) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Comparing archives...")
                        .font(Typography.subheadline)
                        .foregroundColor(AppColors.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = comparisonResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        summarySection(result: result)
                        statsComparison(result: result)
                        aiInsightsSection(result: result)
                        filterBar
                        emailList(result: result)
                    }
                    .padding(Spacing.medium)
                }
            } else {
                EmptyStateView(
                    icon: "doc.on.doc",
                    title: "Ready to Compare",
                    message: "Comparison will begin automatically."
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, idealWidth: 850, minHeight: 500, idealHeight: 650)
        #endif
        .onAppear {
            computeComparison()
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(AppColors.primary)
            Text("Archive Comparison")
                .font(Typography.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.medium)
    }

    // MARK: - Summary
    private func summarySection(result: ComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Summary")
                .font(Typography.title3)
                .fontWeight(.bold)

            #if os(iOS)
            VStack(spacing: Spacing.small) {
                statCard(
                    title: "Only in \(nameA)",
                    count: result.onlyInA.count,
                    color: .blue,
                    icon: "a.circle.fill"
                )
                statCard(
                    title: "Common",
                    count: result.common.count,
                    color: .green,
                    icon: "equal.circle.fill"
                )
                statCard(
                    title: "Only in \(nameB)",
                    count: result.onlyInB.count,
                    color: .orange,
                    icon: "b.circle.fill"
                )
            }
            #else
            HStack(spacing: Spacing.large) {
                statCard(
                    title: "Only in \(nameA)",
                    count: result.onlyInA.count,
                    color: .blue,
                    icon: "a.circle.fill"
                )
                statCard(
                    title: "Common",
                    count: result.common.count,
                    color: .green,
                    icon: "equal.circle.fill"
                )
                statCard(
                    title: "Only in \(nameB)",
                    count: result.onlyInB.count,
                    color: .orange,
                    icon: "b.circle.fill"
                )
            }
            #endif

            Text("\(nameA) has \(result.onlyInA.count) unique email\(result.onlyInA.count == 1 ? "" : "s"), \(nameB) has \(result.onlyInB.count) unique, \(result.common.count) common")
                .font(Typography.footnote)
                .foregroundColor(AppColors.secondary)
                .padding(.top, Spacing.xxSmall)
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func statCard(title: String, count: Int, color: Color, icon: String) -> some View {
        VStack(spacing: Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text("\(count)")
                .font(.system(.title, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.small)
        .background(color.opacity(0.08))
        .cornerRadius(CornerRadius.medium)
    }

    // MARK: - Stats Comparison
    private func statsComparison(result: ComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Archive Statistics")
                .font(Typography.headline)
                .fontWeight(.semibold)

            #if os(iOS)
            VStack(spacing: Spacing.small) {
                archiveStatsColumn(name: nameA, stats: result.statsA, color: .blue)
                Divider()
                archiveStatsColumn(name: nameB, stats: result.statsB, color: .orange)
            }
            #else
            HStack(alignment: .top, spacing: Spacing.medium) {
                archiveStatsColumn(name: nameA, stats: result.statsA, color: .blue)
                Divider()
                archiveStatsColumn(name: nameB, stats: result.statsB, color: .orange)
            }
            #endif
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func archiveStatsColumn(name: String, stats: ArchiveStats, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack(spacing: Spacing.xxSmall) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(Typography.callout)
                    .fontWeight(.semibold)
            }

            Group {
                statsRow(label: "Total Emails", value: "\(stats.totalCount)")
                statsRow(label: "Date Range", value: stats.dateRange)
                statsRow(label: "Unique Senders", value: "\(stats.uniqueSenders)")
                statsRow(label: "Avg Sentiment", value: String(format: "%.2f", stats.avgSentiment))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Spacer()
            Text(value)
                .font(Typography.caption1)
                .fontWeight(.medium)
        }
    }

    // MARK: - Filter Bar
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Filter")
                .font(Typography.callout)
                .fontWeight(.semibold)
            Picker("Filter", selection: $filter) {
                ForEach(ComparisonFilter.allCases, id: \.rawValue) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            #if os(iOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.segmented)
            #endif
        }
    }

    // MARK: - Email List
    private func emailList(result: ComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let emails = filteredEmails(result: result)
            Text("\(emails.count) email\(emails.count == 1 ? "" : "s")")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            if emails.isEmpty {
                Text("No emails match this filter.")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(Spacing.large)
            } else {
                LazyVStack(spacing: Spacing.xxSmall) {
                    ForEach(Array(emails.prefix(200).enumerated()), id: \.offset) { _, item in
                        comparisonEmailRow(item: item)
                    }
                    if emails.count > 200 {
                        Text("Showing 200 of \(emails.count) emails")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                            .padding(Spacing.small)
                    }
                }
            }
        }
    }

    struct ComparisonEmailItem {
        let email: MBOXParser.RawEmail
        let source: EmailSource
        let matchedEmail: MBOXParser.RawEmail?

        enum EmailSource: String {
            case onlyInA = "A"
            case onlyInB = "B"
            case common = "Both"
        }
    }

    private func filteredEmails(result: ComparisonResult) -> [ComparisonEmailItem] {
        var items: [ComparisonEmailItem] = []

        switch filter {
        case .all:
            items += result.onlyInA.map { ComparisonEmailItem(email: $0, source: .onlyInA, matchedEmail: nil) }
            items += result.common.map { ComparisonEmailItem(email: $0.0, source: .common, matchedEmail: $0.1) }
            items += result.onlyInB.map { ComparisonEmailItem(email: $0, source: .onlyInB, matchedEmail: nil) }
        case .onlyInA:
            items = result.onlyInA.map { ComparisonEmailItem(email: $0, source: .onlyInA, matchedEmail: nil) }
        case .onlyInB:
            items = result.onlyInB.map { ComparisonEmailItem(email: $0, source: .onlyInB, matchedEmail: nil) }
        case .common:
            items = result.common.map { ComparisonEmailItem(email: $0.0, source: .common, matchedEmail: $0.1) }
        }

        return items.sorted { a, b in
            let dateA = MBOXParser.parseDate(a.email.headers["Date"]) ?? .distantPast
            let dateB = MBOXParser.parseDate(b.email.headers["Date"]) ?? .distantPast
            return dateA > dateB
        }
    }

    private func comparisonEmailRow(item: ComparisonEmailItem) -> some View {
        HStack(spacing: Spacing.xSmall) {
            // Source badge
            Text(item.source.rawValue)
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 28, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small)
                        .fill(item.source == .onlyInA ? Color.blue :
                              item.source == .onlyInB ? Color.orange : Color.green)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(item.email.headers["Subject"] ?? "(No Subject)")
                    .font(Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: Spacing.xSmall) {
                    Text(item.email.headers["From"] ?? "Unknown")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                    Text(item.email.headers["Date"] ?? "")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(Spacing.xSmall)
        .background(AppColors.backgroundSecondary.opacity(0.5))
        .cornerRadius(CornerRadius.small)
    }

    // MARK: - AI Insights

    private func aiInsightsSection(result: ComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("AI-Enhanced Analysis")
                    .font(Typography.headline)
                    .fontWeight(.semibold)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                } else if aiInsights == nil {
                    Button {
                        loadAIInsights(result: result)
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
                Text("Tap Enhance with AI for deeper comparison insights beyond NLP statistics.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func loadAIInsights(result: ComparisonResult) {
        isLoadingAI = true
        let allEmails = archiveA + archiveB
        let context = """
        Comparing archive "\(nameA)" (\(archiveA.count) emails, sentiment \(String(format: "%.2f", result.statsA.avgSentiment))) \
        vs "\(nameB)" (\(archiveB.count) emails, sentiment \(String(format: "%.2f", result.statsB.avgSentiment))). \
        Common: \(result.common.count), only in A: \(result.onlyInA.count), only in B: \(result.onlyInB.count).
        """
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .all,
                    emails: allEmails,
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

    // MARK: - Comparison Logic

    private func computeComparison() {
        isComputing = true
        Task.detached(priority: .userInitiated) {
            let result = Self.compare(archiveA: archiveA, archiveB: archiveB)
            await MainActor.run {
                comparisonResult = result
                isComputing = false
            }
        }
    }

    nonisolated static func compare(archiveA: [MBOXParser.RawEmail], archiveB: [MBOXParser.RawEmail]) -> ComparisonResult {
        // Build message-ID index for exact matching
        let messageIDsB = Dictionary(
            archiveB.compactMap { email -> (String, MBOXParser.RawEmail)? in
                guard let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"],
                      !msgID.isEmpty else { return nil }
                return (msgID.trimmingCharacters(in: .whitespacesAndNewlines), email)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Fuzzy matching key: subject + sender + date prefix
        func fuzzyKey(for email: MBOXParser.RawEmail) -> String {
            let subject = (email.headers["Subject"] ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let from = (email.headers["From"] ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let datePrefix = String((email.headers["Date"] ?? "").prefix(16))
            return "\(subject)|\(from)|\(datePrefix)"
        }

        let fuzzyIndexB = Dictionary(
            archiveB.map { (fuzzyKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matchedBIDs = Set<UUID>()
        var common: [(MBOXParser.RawEmail, MBOXParser.RawEmail)] = []
        var onlyInA: [MBOXParser.RawEmail] = []

        for emailA in archiveA {
            let msgIDA = (emailA.headers["Message-ID"] ?? emailA.headers["Message-Id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Try exact match by Message-ID first
            if !msgIDA.isEmpty, let matchB = messageIDsB[msgIDA] {
                common.append((emailA, matchB))
                matchedBIDs.insert(matchB.id)
                continue
            }

            // Try fuzzy match
            let keyA = fuzzyKey(for: emailA)
            if let matchB = fuzzyIndexB[keyA], !matchedBIDs.contains(matchB.id) {
                common.append((emailA, matchB))
                matchedBIDs.insert(matchB.id)
                continue
            }

            onlyInA.append(emailA)
        }

        let onlyInB = archiveB.filter { !matchedBIDs.contains($0.id) }

        // Compute stats
        let statsA = computeStats(for: archiveA)
        let statsB = computeStats(for: archiveB)

        return ComparisonResult(
            onlyInA: onlyInA,
            onlyInB: onlyInB,
            common: common,
            statsA: statsA,
            statsB: statsB
        )
    }

    nonisolated static func computeStats(for emails: [MBOXParser.RawEmail]) -> ArchiveStats {
        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateRange: String
        if let first = dates.first, let last = dates.last {
            dateRange = "\(formatter.string(from: first)) - \(formatter.string(from: last))"
        } else {
            dateRange = "N/A"
        }

        let uniqueSenders = Set(
            emails.compactMap { $0.headers["From"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        ).count

        let sentiment = EmailNLPEngine.averageSentiment(of: emails)

        return ArchiveStats(
            totalCount: emails.count,
            dateRange: dateRange,
            uniqueSenders: uniqueSenders,
            avgSentiment: sentiment.average
        )
    }
}
