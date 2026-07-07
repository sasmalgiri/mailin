//
//  CommunicationPatternsView.swift
//  mailin
//
//  Analyzes communication patterns including contact stats, hourly/weekday activity, and response times.
//

import SwiftUI
import Charts
import NaturalLanguage

// MARK: - Communication Pattern Analyzer

struct CommunicationPatternAnalyzer {

    struct ContactStats: Identifiable {
        let id: UUID
        let address: String
        let displayName: String
        let totalEmails: Int
        let sent: Int
        let received: Int
        let avgResponseTimeHours: Double?
        let firstContact: Date?
        let lastContact: Date?
        let sentimentAverage: Double
        let activityScore: Double

        init(
            id: UUID = UUID(),
            address: String,
            displayName: String,
            totalEmails: Int,
            sent: Int,
            received: Int,
            avgResponseTimeHours: Double?,
            firstContact: Date?,
            lastContact: Date?,
            sentimentAverage: Double,
            activityScore: Double
        ) {
            self.id = id
            self.address = address
            self.displayName = displayName
            self.totalEmails = totalEmails
            self.sent = sent
            self.received = received
            self.avgResponseTimeHours = avgResponseTimeHours
            self.firstContact = firstContact
            self.lastContact = lastContact
            self.sentimentAverage = sentimentAverage
            self.activityScore = activityScore
        }
    }

    struct HourlyPattern: Identifiable {
        let id: UUID
        let hour: Int
        let count: Int

        init(id: UUID = UUID(), hour: Int, count: Int) {
            self.id = id
            self.hour = hour
            self.count = count
        }
    }

    struct WeekdayPattern: Identifiable {
        let id: UUID
        let weekday: Int  // 1=Sun, 7=Sat
        let count: Int

        init(id: UUID = UUID(), weekday: Int, count: Int) {
            self.id = id
            self.weekday = weekday
            self.count = count
        }
    }

    static func analyzeContacts(emails: [MBOXParser.RawEmail], senderEmail: String) -> [ContactStats] {
        let normalizedSender = senderEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        struct ContactData {
            var address: String
            var displayName: String
            var sent: Int = 0
            var received: Int = 0
            var dates: [Date] = []
            var sentimentScores: [Double] = []
            var responseTimes: [Double] = []
        }

        var contactMap: [String: ContactData] = [:]
        let tagger = NLTagger(tagSchemes: [.sentimentScore])

        // Build thread lookup: messageID -> date for response time calculation
        var messageIDtoDate: [String: Date] = [:]
        for email in emails {
            if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"],
               let date = MBOXParser.parseDate(email.headers["Date"]) {
                messageIDtoDate[msgID] = date
            }
        }

        for email in emails {
            guard let date = MBOXParser.parseDate(email.headers["Date"]) else { continue }

            let fromRaw = email.headers["From"] ?? ""
            let fromAddress = extractAddress(from: fromRaw).lowercased()
            let fromName = extractDisplayName(from: fromRaw)
            let isSent = fromAddress == normalizedSender || email.messageType.lowercased() == "sent"

            // Compute sentiment for this email
            let body = bodyText(for: email)
            var sentiment = 0.0
            if !body.isEmpty {
                tagger.string = body
                let (tag, _) = tagger.tag(at: body.startIndex, unit: .paragraph, scheme: .sentimentScore)
                sentiment = Double(tag?.rawValue ?? "0") ?? 0.0
            }

            // Response time: if this is a reply, find the original
            var responseTimeHours: Double?
            if let inReplyTo = email.inReplyTo, let originalDate = messageIDtoDate[inReplyTo] {
                let interval = date.timeIntervalSince(originalDate)
                if interval > 0 && interval < 30 * 24 * 3600 { // Reasonable: < 30 days
                    responseTimeHours = interval / 3600
                }
            }

            if isSent {
                // For sent emails, track the recipient(s)
                let toRaw = email.headers["To"] ?? ""
                let recipients = toRaw.components(separatedBy: ",")
                for recipient in recipients {
                    let addr = extractAddress(from: recipient).lowercased()
                    guard !addr.isEmpty, addr != normalizedSender else { continue }
                    let name = extractDisplayName(from: recipient)
                    if contactMap[addr] == nil {
                        contactMap[addr] = ContactData(address: addr, displayName: name)
                    }
                    contactMap[addr]?.sent += 1
                    contactMap[addr]?.dates.append(date)
                    contactMap[addr]?.sentimentScores.append(sentiment)
                    if let rt = responseTimeHours {
                        contactMap[addr]?.responseTimes.append(rt)
                    }
                }
            } else {
                // Received email
                let addr = fromAddress
                guard !addr.isEmpty else { continue }
                if contactMap[addr] == nil {
                    contactMap[addr] = ContactData(address: addr, displayName: fromName)
                }
                contactMap[addr]?.received += 1
                contactMap[addr]?.dates.append(date)
                contactMap[addr]?.sentimentScores.append(sentiment)
                if let rt = responseTimeHours {
                    contactMap[addr]?.responseTimes.append(rt)
                }
            }
        }

        let now = Date()
        let maxRecencyDays: Double = 365

        return contactMap.values.map { data in
            let total = data.sent + data.received
            let sortedDates = data.dates.sorted()
            let firstContact = sortedDates.first
            let lastContact = sortedDates.last
            let avgSentiment = data.sentimentScores.isEmpty ? 0 : data.sentimentScores.reduce(0, +) / Double(data.sentimentScores.count)
            let avgResponseTime = data.responseTimes.isEmpty ? nil : data.responseTimes.reduce(0, +) / Double(data.responseTimes.count)

            // Activity score: combo of frequency + recency
            let frequencyScore = min(Double(total) / 50.0, 1.0) // Normalize: 50+ emails = max
            let recencyScore: Double
            if let last = lastContact {
                let daysSince = now.timeIntervalSince(last) / 86400
                recencyScore = max(0, 1.0 - daysSince / maxRecencyDays)
            } else {
                recencyScore = 0
            }
            let activityScore = (frequencyScore * 0.6 + recencyScore * 0.4)

            return ContactStats(
                address: data.address,
                displayName: data.displayName.isEmpty ? data.address : data.displayName,
                totalEmails: total,
                sent: data.sent,
                received: data.received,
                avgResponseTimeHours: avgResponseTime,
                firstContact: firstContact,
                lastContact: lastContact,
                sentimentAverage: avgSentiment,
                activityScore: activityScore
            )
        }
        .sorted { $0.activityScore > $1.activityScore }
    }

    static func analyzeHourlyPatterns(emails: [MBOXParser.RawEmail]) -> [HourlyPattern] {
        let calendar = Calendar.current
        var hourCounts = [Int](repeating: 0, count: 24)

        for email in emails {
            if let date = MBOXParser.parseDate(email.headers["Date"]) {
                let hour = calendar.component(.hour, from: date)
                hourCounts[hour] += 1
            }
        }

        return (0..<24).map { HourlyPattern(hour: $0, count: hourCounts[$0]) }
    }

    static func analyzeWeekdayPatterns(emails: [MBOXParser.RawEmail]) -> [WeekdayPattern] {
        let calendar = Calendar.current
        var dayCounts = [Int](repeating: 0, count: 7)

        for email in emails {
            if let date = MBOXParser.parseDate(email.headers["Date"]) {
                let weekday = calendar.component(.weekday, from: date) // 1=Sun, 7=Sat
                dayCounts[weekday - 1] += 1
            }
        }

        return (0..<7).map { WeekdayPattern(weekday: $0 + 1, count: dayCounts[$0]) }
    }

    static func averageResponseTime(emails: [MBOXParser.RawEmail], senderEmail: String) -> Double? {
        let normalizedSender = senderEmail.lowercased()

        // Build messageID -> date map
        var messageIDtoDate: [String: Date] = [:]
        for email in emails {
            if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"],
               let date = MBOXParser.parseDate(email.headers["Date"]) {
                messageIDtoDate[msgID] = date
            }
        }

        // Find sent replies and compute response times
        var responseTimes: [Double] = []
        for email in emails {
            let from = extractAddress(from: email.headers["From"] ?? "").lowercased()
            let isSent = from == normalizedSender || email.messageType.lowercased() == "sent"
            guard isSent else { continue }

            let subject = (email.headers["Subject"] ?? "").lowercased()
            let isReply = subject.hasPrefix("re:") || email.inReplyTo != nil

            guard isReply,
                  let replyDate = MBOXParser.parseDate(email.headers["Date"]) else { continue }

            // Try to find the original message
            if let inReplyTo = email.inReplyTo, let originalDate = messageIDtoDate[inReplyTo] {
                let interval = replyDate.timeIntervalSince(originalDate)
                if interval > 0 && interval < 30 * 24 * 3600 {
                    responseTimes.append(interval / 3600)
                }
            }
        }

        guard !responseTimes.isEmpty else { return nil }
        return responseTimes.reduce(0, +) / Double(responseTimes.count)
    }

    // MARK: - Helpers

    private static func extractAddress(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.range(of: "<"), let close = trimmed.range(of: ">") {
            return String(trimmed[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.contains("@") { return trimmed }
        return ""
    }

    private static func extractDisplayName(from header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.range(of: "<") {
            let name = trimmed[trimmed.startIndex..<open.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return extractAddress(from: trimmed)
    }

    private static func bodyText(for email: MBOXParser.RawEmail) -> String {
        if !email.plainBody.isEmpty { return email.plainBody }
        if !email.htmlBody.isEmpty {
            return email.htmlBody
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}

// MARK: - Communication Patterns View

struct CommunicationPatternsView: View {
    let emails: [MBOXParser.RawEmail]
    var senderEmail: String = ""
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss

    @State private var contacts: [CommunicationPatternAnalyzer.ContactStats] = []
    @State private var hourlyPatterns: [CommunicationPatternAnalyzer.HourlyPattern] = []
    @State private var weekdayPatterns: [CommunicationPatternAnalyzer.WeekdayPattern] = []
    @State private var avgResponseTime: Double?
    @State private var isAnalyzing = false
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @State private var showTutorial = false

    private let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isAnalyzing {
                VStack {
                    Spacer()
                    ProgressView("Analyzing communication patterns...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if contacts.isEmpty && !isAnalyzing {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "No Data",
                        message: "Import an email archive to analyze communication patterns."
                    )
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: Spacing.large) {
                        overallStats
                        aiInsightsSection
                        hourlyChart
                        weekdayChart
                        contactList
                        responseTimeSection
                    }
                    .padding(Spacing.large)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
        .background(AppColors.backgroundTertiary)
        .featureTutorial(.communicationPatterns, key: "communication_patterns_tutorial_seen", isPresented: $showTutorial)
        .task { await analyzePatterns() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2)
                    .adaptiveIconGradient(colors: [.purple, .blue])
                VStack(alignment: .leading, spacing: 2) {
                    Text("Communication Patterns")
                        .font(Typography.headline)
                    Text("\(emails.count) emails analyzed")
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

    // MARK: - Overall Stats

    private var overallStats: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()),
            GridItem(.flexible()), GridItem(.flexible())
        ], spacing: Spacing.small) {
            AnimatedStatCard(
                title: "Total Contacts",
                value: "\(contacts.count)",
                icon: "person.2.fill",
                color: .blue
            )
            AnimatedStatCard(
                title: "Avg Response",
                value: formatResponseTime(avgResponseTime),
                icon: "clock.fill",
                color: .orange
            )
            AnimatedStatCard(
                title: "Busiest Hour",
                value: busiestHourLabel,
                icon: "clock.badge",
                color: .purple
            )
            AnimatedStatCard(
                title: "Busiest Day",
                value: busiestDayLabel,
                icon: "calendar",
                color: .green
            )
        }
    }

    // MARK: - AI Insights

    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("AI-Enhanced Analysis")
                    .font(Typography.headline)
                Spacer()
                if isLoadingAI {
                    ProgressView()
                        .controlSize(.small)
                } else if aiInsights == nil {
                    Button {
                        loadAIInsights()
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
                Text("Tap Enhance with AI for deeper communication pattern insights.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func loadAIInsights() {
        isLoadingAI = true
        let topNames = contacts.prefix(5).map { "\($0.displayName) (\($0.totalEmails))" }.joined(separator: ", ")
        let context = """
        Communication patterns across \(emails.count) emails with \(contacts.count) contacts. \
        Top contacts: \(topNames). \
        Avg response time: \(avgResponseTime.map { String(format: "%.1f hours", $0) } ?? "N/A").
        """
        let emailsCopy = emails
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .entity,
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

    // MARK: - Hourly Activity Chart

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Hourly Activity", systemImage: "clock")
                .font(Typography.headline)

            if hourlyPatterns.isEmpty {
                Text("No hourly data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart(hourlyPatterns) { pattern in
                    BarMark(
                        x: .value("Hour", "\(pattern.hour):00"),
                        y: .value("Emails", pattern.count)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.purple, .purple.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(CornerRadius.small)
                }
                .chartXAxisLabel("Hour of Day")
                .chartYAxisLabel("Emails")
                .frame(height: 200)
            }
        }
        .cardStyle()
    }

    // MARK: - Weekday Activity Chart

    private var weekdayChart: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Weekday Activity", systemImage: "calendar")
                .font(Typography.headline)

            if weekdayPatterns.isEmpty {
                Text("No weekday data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                Chart(weekdayPatterns) { pattern in
                    BarMark(
                        x: .value("Day", weekdayName(pattern.weekday)),
                        y: .value("Emails", pattern.count)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.green, .teal],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(CornerRadius.small)
                }
                .chartXAxisLabel("Day of Week")
                .chartYAxisLabel("Emails")
                .frame(height: 180)
            }
        }
        .cardStyle()
    }

    // MARK: - Contact List

    private var contactList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Contact Activity", systemImage: "person.crop.circle")
                .font(Typography.headline)

            let topContacts = Array(contacts.prefix(20))
            if topContacts.isEmpty {
                Text("No contact data available.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else {
                VStack(spacing: Spacing.xxSmall) {
                    // Header row
                    HStack {
                        Text("Contact")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Total")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .frame(width: 45)
                        Text("Sent")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .frame(width: 40)
                        Text("Recv")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .frame(width: 40)
                        Text("Sentiment")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .frame(width: 65)
                        Text("Activity")
                            .font(Typography.caption2)
                            .fontWeight(.semibold)
                            .frame(width: 80)
                    }
                    .padding(.horizontal, Spacing.xSmall)
                    .foregroundColor(AppColors.secondary)

                    Divider()

                    ForEach(topContacts) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func contactRow(_ contact: CommunicationPatternAnalyzer.ContactStats) -> some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                ContactAvatar(name: contact.displayName, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(contact.displayName)
                        .font(Typography.caption1)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(contact.address)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(contact.totalEmails)")
                .font(Typography.caption1)
                .fontWeight(.medium)
                .frame(width: 45)

            Text("\(contact.sent)")
                .font(Typography.caption2)
                .foregroundColor(AppColors.sentEmail)
                .frame(width: 40)

            Text("\(contact.received)")
                .font(Typography.caption2)
                .foregroundColor(AppColors.receivedEmail)
                .frame(width: 40)

            sentimentIndicator(contact.sentimentAverage)
                .frame(width: 65)

            // Activity bar
            activityBar(score: contact.activityScore)
                .frame(width: 80)
        }
        .padding(.vertical, Spacing.xxxSmall)
        .padding(.horizontal, Spacing.xSmall)
    }

    private func sentimentIndicator(_ score: Double) -> some View {
        HStack(spacing: 2) {
            Circle()
                .fill(score > 0.4 ? AppColors.success : (score < -0.4 ? AppColors.error : AppColors.warning))
                .frame(width: 6, height: 6)
            Text(String(format: "%.2f", score))
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
    }

    private func activityBar(score: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.separator.opacity(0.3))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * min(max(score, 0), 1))
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    // MARK: - Response Time Section

    private var responseTimeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("Response Time Overview", systemImage: "timer")
                .font(Typography.headline)

            if let avgRT = avgResponseTime {
                HStack(spacing: Spacing.large) {
                    VStack(spacing: Spacing.xxSmall) {
                        Text(formatResponseTime(avgRT))
                            .font(Typography.title2)
                            .fontWeight(.bold)
                        Text("Average Response Time")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }

                    Divider()
                        .frame(height: 40)

                    VStack(spacing: Spacing.xxSmall) {
                        let contactsWithRT = contacts.filter { $0.avgResponseTimeHours != nil }
                        Text("\(contactsWithRT.count)")
                            .font(Typography.title2)
                            .fontWeight(.bold)
                        Text("Contacts with Response Data")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                }

                // Response time distribution for top contacts
                let contactsWithRT = contacts.filter { $0.avgResponseTimeHours != nil }.prefix(10)
                if !contactsWithRT.isEmpty {
                    Chart(Array(contactsWithRT)) { contact in
                        BarMark(
                            x: .value("Hours", contact.avgResponseTimeHours ?? 0),
                            y: .value("Contact", contact.displayName)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.orange, .orange.opacity(0.5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(CornerRadius.small)
                    }
                    .chartXAxisLabel("Hours")
                    .frame(height: CGFloat(contactsWithRT.count) * 30 + 40)
                }
            } else {
                Text("Not enough reply data to compute response times. Response time analysis requires emails with In-Reply-To headers.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .cardStyle()
    }

    // MARK: - Computation

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private func analyzePatterns() async {
        guard !emails.isEmpty else { return }
        isAnalyzing = true

        let emailsCopy = emails
        let sender = senderEmail

        let result = await Task.detached { () -> (
            [CommunicationPatternAnalyzer.ContactStats],
            [CommunicationPatternAnalyzer.HourlyPattern],
            [CommunicationPatternAnalyzer.WeekdayPattern],
            Double?
        ) in
            let contacts = CommunicationPatternAnalyzer.analyzeContacts(emails: emailsCopy, senderEmail: sender)
            let hourly = CommunicationPatternAnalyzer.analyzeHourlyPatterns(emails: emailsCopy)
            let weekday = CommunicationPatternAnalyzer.analyzeWeekdayPatterns(emails: emailsCopy)
            let avgRT = CommunicationPatternAnalyzer.averageResponseTime(emails: emailsCopy, senderEmail: sender)
            return (contacts, hourly, weekday, avgRT)
        }.value

        await MainActor.run {
            contacts = result.0
            hourlyPatterns = result.1
            weekdayPatterns = result.2
            avgResponseTime = result.3
            isAnalyzing = false
        }
    }

    // MARK: - Helpers

    private func weekdayName(_ weekday: Int) -> String {
        let index = weekday - 1
        guard index >= 0, index < weekdayNames.count else { return "?" }
        return weekdayNames[index]
    }

    private var busiestHourLabel: String {
        guard let busiest = hourlyPatterns.max(by: { $0.count < $1.count }), busiest.count > 0 else { return "--" }
        return "\(busiest.hour):00"
    }

    private var busiestDayLabel: String {
        guard let busiest = weekdayPatterns.max(by: { $0.count < $1.count }), busiest.count > 0 else { return "--" }
        return weekdayName(busiest.weekday)
    }

    private func formatResponseTime(_ hours: Double?) -> String {
        guard let hours = hours else { return "--" }
        if hours < 1 { return String(format: "%.0fm", hours * 60) }
        if hours < 24 { return String(format: "%.1fh", hours) }
        let days = hours / 24
        return String(format: "%.1fd", days)
    }
}
