import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif

struct EmailAnalyticsView: View {
    let emails: [MBOXParser.RawEmail]
    @Environment(\.dismiss) private var dismiss
    @State private var analyticsData: AnalyticsData?
    @State private var isComputing = false
    @State private var computeStage: String = ""
    @State private var exportError: String?
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif

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
        .frame(minWidth: 700, idealWidth: 900, minHeight: 550, idealHeight: 700)
        #endif
        .background(AppColors.backgroundTertiary)
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
                    Text("\(emails.count) emails analyzed")
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

                HStack(spacing: Spacing.small) {
                    ComputeStageIndicator(label: "Sentiment", isActive: computeStage.contains("Sentiment"), isDone: computeStage.contains("Timeline") || computeStage.contains("Contact") || computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Timeline", isActive: computeStage.contains("Timeline"), isDone: computeStage.contains("Contact") || computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Contacts", isActive: computeStage.contains("Contact"), isDone: computeStage.contains("Language") || computeStage.contains("Topic") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "NLP", isActive: computeStage.contains("Language") || computeStage.contains("Topic"), isDone: computeStage.contains("Compliance") || computeStage.contains("Done"))
                    ComputeStageIndicator(label: "Compliance", isActive: computeStage.contains("Compliance"), isDone: computeStage.contains("Done"))
                }
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
        }
    }

    private var adaptiveStatColumns: [GridItem] {
        #if os(iOS)
        if UIScreen.main.bounds.width < 500 {
            return [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        }
        #endif
        return [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
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

            let maxCount = data.contactRelationships.first?.count ?? 1

            ForEach(data.contactRelationships) { rel in
                HStack(spacing: Spacing.xSmall) {
                    Text(truncateEmail(rel.from))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .frame(maxWidth: 160, alignment: .trailing)
                        .lineLimit(1)

                    HStack(spacing: 2) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2)
                            .foregroundColor(.purple.opacity(0.7))
                    }

                    Text(truncateEmail(rel.to))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .frame(maxWidth: 160, alignment: .leading)
                        .lineLimit(1)

                    Spacer()

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * CGFloat(rel.count) / CGFloat(maxCount)))
                    }
                    .frame(width: 80, height: 8)

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
                                .font(Typography.caption2)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 2) {
                            Text(days[day])
                                .font(Typography.caption2)
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

    // MARK: - Compute

    private func computeAnalytics() async {
        isComputing = true
        let emailsCopy = emails

        let data = await Task.detached(priority: .userInitiated) {
            var result = AnalyticsData()
            result.totalCount = emailsCopy.count
            result.sentCount = emailsCopy.filter { $0.messageType == "sent" }.count
            result.receivedCount = emailsCopy.filter { $0.messageType == "received" }.count

            await MainActor.run { computeStage = "Sentiment analysis..." }
            let sentiment = EmailNLPEngine.averageSentiment(of: emailsCopy)
            result.avgSentiment = sentiment.average
            result.sentimentLabel = sentiment.label
            result.sentimentBuckets = [
                SentimentBucket(label: "Positive", count: sentiment.positive, color: .green),
                SentimentBucket(label: "Neutral", count: sentiment.neutral, color: .gray),
                SentimentBucket(label: "Negative", count: sentiment.negative, color: .red)
            ]

            await MainActor.run { computeStage = "Timeline computation..." }
            result.timelineBuckets = Self.computeTimeline(emails: emailsCopy)

            await MainActor.run { computeStage = "Contact analysis..." }
            result.topContacts = Self.computeTopContacts(emails: emailsCopy)

            await MainActor.run { computeStage = "Language detection..." }
            result.languages = EmailNLPEngine.detectLanguages(in: emailsCopy)

            await MainActor.run { computeStage = "Topic extraction..." }
            result.topTopics = EmailNLPEngine.extractTopics(from: emailsCopy, limit: 12)

            await MainActor.run { computeStage = "Heatmap & attachments..." }
            result.heatmapData = Self.computeHeatmap(emails: emailsCopy)
            result.attachmentTypes = Self.computeAttachmentTypes(emails: emailsCopy)
            result.totalAttachments = emailsCopy.reduce(0) { $0 + $1.attachments.count }
            result.domainCounts = Self.computeDomainCounts(emails: emailsCopy)
            result.sizeDistribution = Self.computeSizeDistribution(emails: emailsCopy)

            await MainActor.run { computeStage = "Contact relationships..." }
            result.contactRelationships = Self.computeContactRelationships(emails: emailsCopy)

            await MainActor.run { computeStage = "Compliance & priority scan..." }
            result.piiCounts = EmailNLPEngine.piiSummary(in: emailsCopy)
            let priorities = EmailNLPEngine.scoreAllPriorities(emailsCopy)
            result.highPriorityCount = priorities.filter { $0.level == .high }.count
            result.mediumPriorityCount = priorities.filter { $0.level == .medium }.count
            result.totalStorageMB = Double(emailsCopy.reduce(0) { $0 + $1.rawSource.utf8.count }) / (1024.0 * 1024.0)

            await MainActor.run { computeStage = "Done" }
            return result
        }.value

        withAnimation(AnimationTiming.normal) {
            analyticsData = data
            isComputing = false
        }
    }

    nonisolated private static func computeTimeline(emails: [MBOXParser.RawEmail]) -> [TimelineBucket] {
        let calendar = Calendar.current
        var bucketMap: [Date: (sent: Int, received: Int)] = [:]

        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            var entry = bucketMap[month, default: (sent: 0, received: 0)]
            if email.messageType == "sent" {
                entry.sent += 1
            } else {
                entry.received += 1
            }
            bucketMap[month] = entry
        }

        return bucketMap.sorted { $0.key < $1.key }.map {
            TimelineBucket(date: $0.key, sent: $0.value.sent, received: $0.value.received)
        }
    }

    nonisolated private static func computeTopContacts(emails: [MBOXParser.RawEmail]) -> [ContactCount] {
        var counts: [String: Int] = [:]
        for email in emails {
            let from = email.headers["From"] ?? ""
            if !from.isEmpty {
                let clean = from.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) ?? from
                counts[clean.lowercased(), default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(10)
            .map { ContactCount(address: $0.key, count: $0.value) }
    }

    nonisolated private static func computeHeatmap(emails: [MBOXParser.RawEmail]) -> [HeatmapCell] {
        let calendar = Calendar.current
        var grid: [Int: [Int: Int]] = [:]
        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }
            let dow = calendar.component(.weekday, from: date) - 1
            let hour = (calendar.component(.hour, from: date) / 3) * 3
            grid[dow, default: [:]][hour, default: 0] += 1
        }
        var cells: [HeatmapCell] = []
        for day in 0..<7 {
            for h in stride(from: 0, to: 24, by: 3) {
                let count = grid[day]?[h] ?? 0
                cells.append(HeatmapCell(dayOfWeek: day, hour: h, count: count))
            }
        }
        return cells
    }

    nonisolated private static func computeAttachmentTypes(emails: [MBOXParser.RawEmail]) -> [AttachmentTypeCount] {
        var typeCounts: [String: Int] = [:]
        for email in emails {
            for att in email.attachments {
                let ext = (att.filename as NSString).pathExtension.lowercased()
                let label = ext.isEmpty ? "unknown" : ext
                typeCounts[label, default: 0] += 1
            }
        }
        return typeCounts.sorted { $0.value > $1.value }
            .map { AttachmentTypeCount(fileType: $0.key, count: $0.value) }
    }

    nonisolated private static func computeDomainCounts(emails: [MBOXParser.RawEmail]) -> [DomainCount] {
        var counts: [String: Int] = [:]
        for email in emails {
            for domain in email.domains {
                counts[domain.lowercased(), default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(15)
            .map { DomainCount(domain: $0.key, count: $0.value) }
    }

    nonisolated private static func computeSizeDistribution(emails: [MBOXParser.RawEmail]) -> [SizeBucket] {
        var buckets: [String: Int] = [
            "< 1 KB": 0,
            "1-10 KB": 0,
            "10-100 KB": 0,
            "100 KB-1 MB": 0,
            "> 1 MB": 0
        ]
        let order = ["< 1 KB", "1-10 KB", "10-100 KB", "100 KB-1 MB", "> 1 MB"]

        for email in emails {
            let size = email.rawSource.utf8.count
            switch size {
            case ..<1024:
                buckets["< 1 KB", default: 0] += 1
            case 1024..<10240:
                buckets["1-10 KB", default: 0] += 1
            case 10240..<102400:
                buckets["10-100 KB", default: 0] += 1
            case 102400..<1048576:
                buckets["100 KB-1 MB", default: 0] += 1
            default:
                buckets["> 1 MB", default: 0] += 1
            }
        }
        return order.map { SizeBucket(label: $0, count: buckets[$0] ?? 0) }
    }

    nonisolated private static func computeContactRelationships(emails: [MBOXParser.RawEmail]) -> [ContactRelationship] {
        var pairs: [String: Int] = [:]
        for email in emails {
            let fromRaw = email.headers["From"] ?? ""
            let from = fromRaw.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces).lowercased() ?? fromRaw.lowercased()
            guard !from.isEmpty else { continue }

            let toRaw = email.headers["To"] ?? ""
            let recipients = toRaw.components(separatedBy: ",").compactMap { addr -> String? in
                let cleaned = addr.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces).lowercased() ?? addr.trimmingCharacters(in: .whitespaces).lowercased()
                return cleaned.isEmpty ? nil : cleaned
            }

            for to in recipients {
                let key = [from, to].sorted().joined(separator: "↔")
                pairs[key, default: 0] += 1
            }
        }

        return pairs.sorted { $0.value > $1.value }
            .prefix(15)
            .map { pair in
                let parts = pair.key.components(separatedBy: "↔")
                guard let from = parts.first else { return ContactRelationship(from: "?", to: "?", count: pair.value) }
                return ContactRelationship(from: from, to: parts.count > 1 ? parts[1] : "?", count: pair.value)
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
