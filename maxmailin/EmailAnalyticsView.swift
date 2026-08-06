import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif

struct EmailAnalyticsView: View {
    /// Legacy filtered-selection callers still pass an array; whole-archive
    /// callers pass nil, and analytics stream from the activated SQLite store
    /// (bounded). Migrating the last array callers off `emails` finishes this.
    var emails: [MBOXParser.RawEmail]? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var analyticsData: AnalyticsData?
    @State private var isComputing = false
    @State private var computeStage: String = ""
    @State private var exportError: String?
    @State private var aiEnhanced = false
    @State private var isLoadingAI = false
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif
    @State private var showTutorial = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isComputing {
                computingOverlay
            } else if let data = analyticsData {
                ScrollView {
                    VStack(spacing: Spacing.large) {
                        overviewCards(data: data)
                        sentimentSection(data: data)
                        timelineSection(data: data)
                        heatmapSection(data: data)
                        topContactsSection(data: data)
                        if !data.contactRelationships.isEmpty {
                            contactNetworkSection(data: data)
                        }
                        domainSection(data: data)
                        if !data.attachmentTypes.isEmpty {
                            attachmentTypeSection(data: data)
                        }
                        if !data.sizeDistribution.isEmpty {
                            sizeDistributionSection(data: data)
                        }
                        if !data.languages.isEmpty {
                            languageSection(data: data)
                        }
                        if !data.topTopics.isEmpty {
                            topicsSection(data: data)
                        }
                        complianceSection(data: data)
                        aiInsightsSection(data: data)
                    }
                    .padding(Spacing.large)
                }
            } else {
                Spacer()
                ProgressView("Preparing analytics...")
                Spacer()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 900, minHeight: 380, idealHeight: 700)
        #endif
        .background(AppColors.backgroundTertiary)
        .featureTutorial(.emailAnalytics, key: "email_analytics_tutorial_seen", isPresented: $showTutorial)
        .task { await computeAnalytics() }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "An unknown error occurred while saving the file.")
        }
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2)
                    .adaptiveIconGradient(colors: [.blue, .purple])
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email Analytics")
                        .font(Typography.headline)
                    Text("\(analyticsData?.totalCount ?? emails?.count ?? 0) emails analyzed")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            Spacer()

            if analyticsData != nil {
                Button {
                    exportAnalyticsReport()
                } label: {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export analytics as a text report")
                .accessibilityLabel("Export analytics report")
                .accessibilityHint("Save analytics as a text file")
            }

            TutorialHelpButton(showTutorial: $showTutorial)

            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close analytics")
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    // MARK: - Computing Overlay

    private var computingOverlay: some View {
        VStack(spacing: Spacing.large) {
            Spacer()
            VStack(spacing: Spacing.medium) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Analyzing Emails")
                    .font(Typography.title3)
                Text(computeStage)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .animation(.easeInOut, value: computeStage)

                #if os(iOS)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.xSmall) {
                    ComputeStageIndicator(label: "Sentiment", isActive: computeStage.contains("Sentiment"), isDone: computeStage.contains("Timeline") || computeStage.contains("Contact") || computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Timeline", isActive: computeStage.contains("Timeline"), isDone: computeStage.contains("Contact") || computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Contacts", isActive: computeStage.contains("Contact"), isDone: computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "NLP", isActive: computeStage.contains("Language") || computeStage.contains("Topic"), isDone: computeStage.contains("Compliance") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Compliance", isActive: computeStage.contains("Compliance"), isDone: computeStage.contains("Done"))
                }
                #else
                HStack(spacing: Spacing.small) {
                    ComputeStageIndicator(label: "Sentiment", isActive: computeStage.contains("Sentiment"), isDone: computeStage.contains("Timeline") || computeStage.contains("Contact") || computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Timeline", isActive: computeStage.contains("Timeline"), isDone: computeStage.contains("Contact") || computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Contacts", isActive: computeStage.contains("Contact"), isDone: computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "NLP", isActive: computeStage.contains("Language") || computeStage.contains("Topic"), isDone: computeStage.contains("Compliance") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Compliance", isActive: computeStage.contains("Compliance"), isDone: computeStage.contains("Done"))
                }
                #endif
            }
            .padding(Spacing.xLarge)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xLarge)
                    .fill(AppColors.backgroundPrimary.opacity(0.97))
                    .shadow(radius: Shadows.xLarge.radius)
            )
            Spacer()
        }
        .adaptiveHeroBackground(colors: [.blue, .cyan, .teal, .green])
    }

    // MARK: - Overview Cards

    private func overviewCards(data: AnalyticsData) -> some View {
        VStack(spacing: Spacing.small) {
            LazyVGrid(columns: adaptiveStatColumns, spacing: Spacing.small) {
                StatCard(title: "Total", value: "\(data.totalCount)", icon: "envelope.fill", color: .blue)
                StatCard(title: "Sent", value: "\(data.sentCount)", icon: "arrow.up.circle.fill", color: AppColors.sentEmail)
                StatCard(title: "Received", value: "\(data.receivedCount)", icon: "arrow.down.circle.fill", color: AppColors.receivedEmail)
                StatCard(title: "Sentiment", value: data.sentimentLabel, icon: data.sentimentIcon, color: data.sentimentColor)
                StatCard(title: "High Priority", value: "\(data.highPriorityCount)", icon: "exclamationmark.triangle.fill", color: .red)
                StatCard(title: "Med Priority", value: "\(data.mediumPriorityCount)", icon: "exclamationmark.circle.fill", color: .orange)
                StatCard(title: "Attachments", value: "\(data.totalAttachments)", icon: "paperclip", color: .purple)
                StatCard(title: "Storage", value: String(format: "%.1f MB", data.totalStorageMB), icon: "internaldrive", color: .teal)
            }

            Label {
                Text("Statistics computed from email headers and content. Priority levels are determined by NLP analysis of urgency indicators in subject lines and body text.")
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
            }
            .padding(Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(CornerRadius.small)
        }
    }

    private var adaptiveStatColumns: [GridItem] {
        #if os(iOS)
        return [GridItem(.flexible()), GridItem(.flexible())]
        #else
        return [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        #endif
    }

    // MARK: - Sentiment Chart

    private func sentimentSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Sentiment Distribution", systemImage: "face.smiling")
                .font(Typography.headline)

            HStack(spacing: Spacing.large) {
                Chart(data.sentimentBuckets, id: \.label) { bucket in
                    BarMark(
                        x: .value("Category", bucket.label),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(bucket.color)
                    .cornerRadius(CornerRadius.small)
                }
                .chartYAxisLabel("Emails")
                .frame(height: 200)

                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text("Score: \(String(format: "%.2f", data.avgSentiment))")
                        .font(Typography.title3)
                        .fontWeight(.bold)
                    Text("Range: -1.0 to +1.0")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    Divider()
                    SentimentMeter(score: data.avgSentiment)
                        .frame(height: 24)
                }
                .frame(width: 160)
            }

            Label {
                Text("Sentiment ranges from -1.0 (very negative) to +1.0 (very positive). Scores near 0 indicate neutral tone. Computed using Natural Language framework analysis of email body text.")
                    .font(Typography.caption1)
            } icon: {
                Image(systemName: "face.smiling")
                    .foregroundColor(.blue)
            }
            .padding(Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(CornerRadius.small)
        }
        .cardStyle()
    }

    // MARK: - Timeline Chart

    private func timelineSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Email Volume Over Time", systemImage: "chart.line.uptrend.xyaxis")
                .font(Typography.headline)

            if data.timelineBuckets.isEmpty {
                Text("Not enough date data to chart.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart {
                    ForEach(data.timelineBuckets, id: \.date) { bucket in
                        AreaMark(
                            x: .value("Date", bucket.date),
                            y: .value("Sent", bucket.sent)
                        )
                        .foregroundStyle(AppColors.sentEmail.opacity(0.4))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Date", bucket.date),
                            y: .value("Sent", bucket.sent)
                        )
                        .foregroundStyle(AppColors.sentEmail)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))

                        AreaMark(
                            x: .value("Date", bucket.date),
                            y: .value("Received", bucket.received)
                        )
                        .foregroundStyle(AppColors.receivedEmail.opacity(0.3))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Date", bucket.date),
                            y: .value("Received", bucket.received)
                        )
                        .foregroundStyle(AppColors.receivedEmail)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYAxisLabel("Emails")
                .chartForegroundStyleScale([
                    "Sent": AppColors.sentEmail,
                    "Received": AppColors.receivedEmail
                ])
                .frame(height: 220)

                HStack(spacing: Spacing.medium) {
                    ChartLegendDot(color: AppColors.sentEmail, label: "Sent")
                    ChartLegendDot(color: AppColors.receivedEmail, label: "Received")
                }
                .font(Typography.caption1)
            }
        }
        .cardStyle()
    }

    // MARK: - Top Contacts

    private func topContactsSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Top Contacts", systemImage: "person.2.fill")
                .font(Typography.headline)

            if data.topContacts.isEmpty {
                Text("No contact data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart(data.topContacts, id: \.address) { contact in
                    BarMark(
                        x: .value("Emails", contact.count),
                        y: .value("Contact", contact.address)
                    )
                    .foregroundStyle(
                        .linearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(CornerRadius.small)
                    .annotation(position: .trailing) {
                        Text("\(contact.count)")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let str = value.as(String.self) {
                                Text(str.count > 30 ? String(str.prefix(27)) + "..." : str)
                                    .font(Typography.caption2)
                            }
                        }
                    }
                }
                .chartXAxisLabel("Email Count")
                .frame(height: CGFloat(min(data.topContacts.count, 10)) * 32 + 40)
            }
        }
        .cardStyle()
    }

    // MARK: - Contact Network

    private func contactNetworkSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Contact Network", systemImage: "link")
                .font(Typography.headline)

            Text("Top communication pairs by email volume")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            let maxCount = max(data.contactRelationships.first?.count ?? 1, 1)

            ForEach(data.contactRelationships) { rel in
                HStack(spacing: Spacing.xSmall) {
                    Text(truncateEmail(rel.from))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        #if os(iOS)
                        .frame(maxWidth: 100, alignment: .trailing)
                        #else
                        .frame(maxWidth: 160, alignment: .trailing)
                        #endif
                        .lineLimit(1)

                    HStack(spacing: 2) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                            .foregroundColor(.purple.opacity(0.7))
                    }

                    Text(truncateEmail(rel.to))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        #if os(iOS)
                        .frame(maxWidth: 100, alignment: .leading)
                        #else
                        .frame(maxWidth: 160, alignment: .leading)
                        #endif
                        .lineLimit(1)

                    Spacer()

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * CGFloat(rel.count) / CGFloat(maxCount)))
                    }
                    #if os(iOS)
                    .frame(width: 60, height: 8)
                    #else
                    .frame(width: 80, height: 8)
                    #endif

                    Text("\(rel.count)")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rel.from) and \(rel.to), \(rel.count) emails exchanged")
            }
        }
        .cardStyle()
    }

    private func truncateEmail(_ email: String) -> String {
        email.count > 24 ? String(email.prefix(21)) + "..." : email
    }

    // MARK: - Languages

    private func languageSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Languages Detected", systemImage: "globe")
                .font(Typography.headline)

            Chart(data.languages, id: \.language) { lang in
                SectorMark(
                    angle: .value("Count", lang.count),
                    innerRadius: .ratio(0.5),
                    angularInset: 2
                )
                .foregroundStyle(by: .value("Language", lang.language))
                .cornerRadius(CornerRadius.small)
                .annotation(position: .overlay) {
                    if lang.percentage > 10 {
                        Text("\(Int(lang.percentage))%")
                            .font(Typography.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(height: 200)
        }
        .cardStyle()
    }

    // MARK: - Topics

    private func topicsSection(data: AnalyticsData) -> some View {
        let entries = data.topTopics.map { TopicEntry(word: $0.word, count: $0.count) }
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Top Topics & Keywords", systemImage: "text.magnifyingglass")
                .font(Typography.headline)

            Chart(entries) { topic in
                BarMark(
                    x: .value("Topic", topic.word),
                    y: .value("Count", topic.count)
                )
                .foregroundStyle(
                    .linearGradient(colors: [.purple, .blue], startPoint: .bottom, endPoint: .top)
                )
                .cornerRadius(CornerRadius.small)
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel(anchor: .topTrailing) {
                        if let str = value.as(String.self) {
                            Text(str)
                                .font(Typography.caption2)
                                .rotationEffect(.degrees(-45))
                        }
                    }
                }
            }
            .chartYAxisLabel("Occurrences")
            .frame(height: 200)
        }
        .cardStyle()
    }

    // MARK: - Export Analytics Report

    private func exportAnalyticsReport() {
        guard let data = analyticsData else { return }
        var report = "mailin Email Analytics Report\n"
        report += "Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))\n"
        report += String(repeating: "=", count: 50) + "\n\n"

        report += "OVERVIEW\n"
        report += "Total emails: \(data.totalCount)\n"
        report += "Sent: \(data.sentCount) | Received: \(data.receivedCount)\n"
        report += "Sentiment: \(data.sentimentLabel) (score: \(String(format: "%.2f", data.avgSentiment)))\n"
        report += "Attachments: \(data.totalAttachments)\n\n"

        report += "TOP CONTACTS\n"
        for contact in data.topContacts {
            report += "  \(contact.address): \(contact.count) emails\n"
        }
        report += "\n"

        report += "TOP DOMAINS\n"
        for domain in data.domainCounts.prefix(10) {
            report += "  \(domain.domain): \(domain.count) emails\n"
        }
        report += "\n"

        if !data.attachmentTypes.isEmpty {
            report += "ATTACHMENT TYPES\n"
            for att in data.attachmentTypes {
                report += "  .\(att.fileType): \(att.count)\n"
            }
            report += "\n"
        }

        if !data.sizeDistribution.isEmpty {
            report += "EMAIL SIZE DISTRIBUTION\n"
            for bucket in data.sizeDistribution where bucket.count > 0 {
                report += "  \(bucket.label): \(bucket.count) emails\n"
            }
            report += "\n"
        }

        if !data.languages.isEmpty {
            report += "LANGUAGES\n"
            for lang in data.languages {
                report += "  \(lang.language): \(lang.count) (\(String(format: "%.0f", lang.percentage))%)\n"
            }
            report += "\n"
        }

        if !data.topTopics.isEmpty {
            report += "TOP TOPICS\n"
            for topic in data.topTopics {
                report += "  \(topic.word): \(topic.count) occurrences\n"
            }
            report += "\n"
        }

        if !data.piiCounts.isEmpty {
            report += "PRIVACY / PII SCAN\n"
            for type in EmailNLPEngine.PIIType.allCases {
                let count = data.piiCounts[type] ?? 0
                if count > 0 {
                    report += "  \(type.rawValue): \(count) instance(s)\n"
                }
            }
            report += "\n"
        }

        report += "PRIORITY ANALYSIS\n"
        report += "High: \(data.highPriorityCount) | Medium: \(data.mediumPriorityCount)\n"
        report += "Storage: \(String(format: "%.1f", data.totalStorageMB)) MB\n\n"

        report += "ACTIVITY HEATMAP (Day x 3-Hour Block)\n"
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        for day in 0..<7 {
            var line = "\(days[day]): "
            for h in stride(from: 0, to: 24, by: 3) {
                let count = data.heatmapData.first(where: { $0.dayOfWeek == day && $0.hour == h })?.count ?? 0
                line += String(format: "%3d ", count)
            }
            report += "  \(line)\n"
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin_analytics_report.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_analytics_report.txt")
        #endif
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            #if os(iOS)
            shareItems = [url]
            showShareSheet = true
            #endif
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Heatmap (Day of Week x Hour)

    private func heatmapSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Activity Heatmap", systemImage: "calendar.badge.clock")
                .font(Typography.headline)

            if data.heatmapData.isEmpty {
                Text("Not enough date data for heatmap.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                let maxCount = data.heatmapData.map(\.count).max() ?? 1
                let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                let hours = stride(from: 0, to: 24, by: 3).map { $0 }

                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Text("")
                            .frame(width: 36)
                        ForEach(hours, id: \.self) { h in
                            Text("\(h)")
                                #if os(iOS)
                                .font(.system(size: 9))
                                #else
                                .font(Typography.caption2)
                                #endif
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 2) {
                            Text(days[day])
                                #if os(iOS)
                                .font(.system(size: 9))
                                #else
                                .font(Typography.caption2)
                                #endif
                                .frame(width: 36, alignment: .trailing)
                            ForEach(hours, id: \.self) { h in
                                let count = data.heatmapData.first(where: { $0.dayOfWeek == day && $0.hour == h })?.count ?? 0
                                let intensity = maxCount > 0 ? Double(count) / Double(maxCount) : 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.blue.opacity(0.1 + intensity * 0.8))
                                    .frame(height: 24)
                                    .overlay(
                                        count > 0 ? Text("\(count)")
                                            .font(.caption2)
                                            .foregroundColor(intensity > 0.5 ? .white : AppColors.secondary) : nil
                                    )
                                    .help(Text(verbatim: "\(days[day]) \(h):00 — \(count) emails"))
                                    .accessibilityLabel("\(days[day]) \(h):00, \(count) emails")
                            }
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Domain Analytics

    private func domainSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Top Domains (Organizations)", systemImage: "building.2")
                .font(Typography.headline)

            if data.domainCounts.isEmpty {
                Text("No domain data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart(data.domainCounts.prefix(10)) { domain in
                    BarMark(
                        x: .value("Emails", domain.count),
                        y: .value("Domain", domain.domain)
                    )
                    .foregroundStyle(
                        .linearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(CornerRadius.small)
                    .annotation(position: .trailing) {
                        Text("\(domain.count)")
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                .chartXAxisLabel("Email Count")
                .frame(height: CGFloat(min(data.domainCounts.count, 10)) * 28 + 40)
            }
        }
        .cardStyle()
    }

    // MARK: - Attachment Type Breakdown

    private func attachmentTypeSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Attachment Types (\(data.totalAttachments) total)", systemImage: "paperclip")
                .font(Typography.headline)

            HStack(spacing: Spacing.large) {
                Chart(data.attachmentTypes.prefix(8)) { att in
                    SectorMark(
                        angle: .value("Count", att.count),
                        innerRadius: .ratio(0.5),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("Type", att.fileType))
                    .cornerRadius(CornerRadius.small)
                }
                .frame(width: 200, height: 200)

                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    ForEach(data.attachmentTypes.prefix(8)) { att in
                        HStack(spacing: Spacing.xxSmall) {
                            Image(systemName: iconForFileType(att.fileType))
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.primary)
                                .frame(width: 14)
                            Text(att.fileType)
                                .font(Typography.caption1)
                            Spacer()
                            Text("\(att.count)")
                                .font(Typography.caption1)
                                .fontWeight(.medium)
                                .foregroundColor(AppColors.secondary)
                        }
                    }
                }
                .frame(minWidth: 140)
            }
        }
        .cardStyle()
    }

    private func iconForFileType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx", "csv": return "tablecells"
        case "zip", "gz", "tar", "rar": return "archivebox"
        case "mp3", "wav", "aac": return "music.note"
        case "mp4", "mov", "avi": return "film"
        default: return "doc"
        }
    }

    // MARK: - Email Size Distribution

    private func sizeDistributionSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Email Size Distribution", systemImage: "chart.bar.fill")
                .font(Typography.headline)

            Chart(data.sizeDistribution) { bucket in
                BarMark(
                    x: .value("Size", bucket.label),
                    y: .value("Count", bucket.count)
                )
                .foregroundStyle(
                    .linearGradient(colors: [.orange, .red], startPoint: .bottom, endPoint: .top)
                )
                .cornerRadius(CornerRadius.small)
            }
            .chartYAxisLabel("Emails")
            .frame(height: 180)
        }
        .cardStyle()
    }

    // MARK: - Compliance & Privacy Section

    private func complianceSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Privacy & Compliance", systemImage: "shield.checkered")
                .font(Typography.headline)

            if data.piiCounts.isEmpty {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("No PII detected in scanned emails")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text("Personally Identifiable Information Found:")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.warning)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.xSmall) {
                        ForEach(EmailNLPEngine.PIIType.allCases, id: \.rawValue) { type in
                            let count = data.piiCounts[type] ?? 0
                            if count > 0 {
                                HStack {
                                    Image(systemName: piiIcon(for: type))
                                        .font(Typography.caption1)
                                        .foregroundColor(.orange)
                                        .frame(width: 16)
                                    Text(type.rawValue)
                                        .font(Typography.caption1)
                                    Spacer()
                                    Text("\(count)")
                                        .font(Typography.caption1)
                                        .fontWeight(.bold)
                                        .foregroundColor(.orange)
                                }
                                .padding(.vertical, Spacing.xxxSmall)
                            }
                        }
                    }

                    Text("Use \"Redacted Export\" in email detail to strip PII before sharing.")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)

                    Label {
                        Text("Personally Identifiable Information (PII) detected using pattern matching — includes phone numbers, email addresses, SSNs, and credit card numbers. Consider redacting PII before producing documents for e-discovery.")
                            .font(Typography.caption1)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.orange)
                    }
                    .padding(Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                }
            }
        }
        .cardStyle()
    }

    private func piiIcon(for type: EmailNLPEngine.PIIType) -> String {
        switch type {
        case .emailAddress: return "at"
        case .phoneNumber: return "phone"
        case .ssnPattern: return "person.text.rectangle"
        case .creditCard: return "creditcard"
        case .ipAddress: return "network"
        case .passportNumber: return "book.closed"
        case .dateOfBirth: return "calendar"
        case .driversLicense: return "car"
        case .iban: return "banknote"
        }
    }

    // MARK: - AI Insights

    private func aiInsightsSection(data: AnalyticsData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Label("AI-Enhanced Insights", systemImage: "cpu")
                    .font(Typography.headline)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing...")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                } else if !aiEnhanced {
                    Button {
                        loadAIInsights()
                    } label: {
                        Label("Enhance with AI", systemImage: "sparkles")
                            .font(Typography.caption1)
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(Typography.caption1)
                }
            }

            if let insights = data.aiInsights {
                Text(.init(insights))
                    .font(Typography.callout)
                    .foregroundColor(AppColors.primary)
                    .textSelection(.enabled)

                Text("Generated by on-device Apple AI experts")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            } else if !aiEnhanced && !isLoadingAI {
                Text("Tap \"Enhance with AI\" to run expert analysis on your emails. NLP analytics above are always available instantly.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .cardStyle()
    }

    private func loadAIInsights() {
        isLoadingAI = true
        let injected = emails
        Task {
            // Bounded context: the filtered selection when injected, else a
            // bounded most-recent working set from the store — never the corpus.
            let emailsForAI: [MBOXParser.RawEmail]
            if let injected {
                emailsForAI = injected
            } else {
                var recent: [MBOXParser.RawEmail] = []
                let stream = ArchiveDataService.shared.streamFullEmails(query: .all, batchSize: 200)
                do {
                    for try await batch in stream {
                        recent.append(contentsOf: batch)
                        if recent.count >= 500 { recent = Array(recent.prefix(500)); break }
                    }
                } catch { /* best-effort context */ }
                emailsForAI = recent
            }
            var insights: String?
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                insights = await FoundationModelEngine.enhanceWithAI(
                    scope: .digest,
                    emails: emailsForAI,
                    context: "Analyze this email archive for key patterns, trends, and notable findings"
                )
            }
            #endif
            withAnimation(AnimationTiming.normal) {
                analyticsData?.aiInsights = insights
                aiEnhanced = true
                isLoadingAI = false
            }
        }
    }

    // MARK: - Compute

    private func computeAnalytics() async {
        isComputing = true
        computeStage = "Analyzing..."
        let data: AnalyticsData
        if let emails {
            // Legacy filtered selection → array path (bounded by the selection).
            data = await ArchiveFullAnalyticsService.shared.compute(emails: emails)
        } else {
            // Whole archive → bounded streaming from the activated store.
            data = (try? await ArchiveFullAnalyticsService.shared.compute(scope: .all)) ?? AnalyticsData()
        }
        withAnimation(AnimationTiming.normal) {
            analyticsData = data
            isComputing = false
        }
    }
}

// MARK: - Data Models

struct AnalyticsData {
    var totalCount = 0
    var sentCount = 0
    var receivedCount = 0
    var avgSentiment: Double = 0
    var sentimentLabel = "N/A"
    var sentimentBuckets: [SentimentBucket] = []
    var timelineBuckets: [TimelineBucket] = []
    var topContacts: [ContactCount] = []
    var languages: [EmailNLPEngine.LanguageResult] = []
    var topTopics: [(word: String, count: Int)] = []
    var heatmapData: [HeatmapCell] = []
    var attachmentTypes: [AttachmentTypeCount] = []
    var domainCounts: [DomainCount] = []
    var sizeDistribution: [SizeBucket] = []
    var totalAttachments = 0
    var piiCounts: [EmailNLPEngine.PIIType: Int] = [:]
    var highPriorityCount = 0
    var mediumPriorityCount = 0
    var totalStorageMB: Double = 0
    var contactRelationships: [ContactRelationship] = []
    var aiInsights: String?

    var sentimentIcon: String {
        if avgSentiment > 0.1 { return "face.smiling.fill" }
        if avgSentiment < -0.1 { return "face.dashed" }
        return "face.smiling"
    }
    var sentimentColor: Color {
        if avgSentiment > 0.1 { return .green }
        if avgSentiment < -0.1 { return .red }
        return .orange
    }
}

struct HeatmapCell: Identifiable {
    let id = UUID()
    let dayOfWeek: Int
    let hour: Int
    let count: Int
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var dayLabel: String {
        guard dayOfWeek >= 0, dayOfWeek < Self.dayNames.count else { return "?" }
        return Self.dayNames[dayOfWeek]
    }
}

struct AttachmentTypeCount: Identifiable {
    let id = UUID()
    let fileType: String
    let count: Int
}

struct DomainCount: Identifiable {
    let id = UUID()
    let domain: String
    let count: Int
}

struct SizeBucket: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
}

struct SentimentBucket {
    let label: String
    let count: Int
    let color: Color
}

struct TimelineBucket {
    let date: Date
    let sent: Int
    let received: Int
}

struct ContactCount {
    let address: String
    let count: Int
}

struct ContactRelationship: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    let count: Int
}

struct TopicEntry: Identifiable {
    let id = UUID()
    let word: String
    let count: Int
}

// MARK: - Subviews

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: Spacing.xSmall) {
            Image(systemName: icon)
                .font(.title2)
                .adaptiveIconGradient(colors: [color, color.opacity(0.6)])
                .accessibilityHidden(true)
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.small)
        .background(.ultraThinMaterial)
        .cornerRadius(CornerRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.large)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct SentimentMeter: View {
    let score: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .fill(
                        LinearGradient(colors: [.red, .orange, .yellow, .green], startPoint: .leading, endPoint: .trailing)
                    )
                let normalized = (score + 1.0) / 2.0
                let xPos = max(4, min(geo.size.width - 4, normalized * geo.size.width))
                Circle()
                    .fill(.white)
                    .shadow(radius: 2)
                    .frame(width: 16, height: 16)
                    .offset(x: xPos - 8)
            }
        }
    }
}

struct ComputeStageIndicator: View {
    let label: String
    let isActive: Bool
    let isDone: Bool

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            ZStack {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if isActive {
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(AppColors.secondary.opacity(0.4))
                }
            }
            .frame(width: 16, height: 16)
            Text(label)
                .font(Typography.caption2)
                .foregroundColor(isDone ? .green : isActive ? .primary : AppColors.secondary.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(isDone ? "complete" : isActive ? "in progress" : "pending")")
    }
}

struct ChartLegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundColor(AppColors.secondary)
        }
    }
}
