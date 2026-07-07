import SwiftUI

struct PredictiveInsightsView: View {
    let emails: [MBOXParser.RawEmail]

    @State private var summary: PredictiveEngine.PredictionSummary?
    @State private var isAnalyzing = false
    @State private var selectedTab: PredTab = .urgency

    enum PredTab: String, CaseIterable {
        case urgency = "Urgency"
        case threads = "Threads"
        case security = "Security"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isAnalyzing {
                analyzingView
            } else if let summary {
                tabBar
                tabContent(summary)
            } else {
                promptView
            }
        }
        .background(AppColors.backgroundPrimary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.linearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text("Predictive Insights")
                    .font(.system(.title3, design: .rounded)).fontWeight(.bold)
                Text("Urgency, outcomes, and risk forecasts")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if summary != nil {
                Button { runAnalysis() } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).fontWeight(.medium)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Spacing.medium)
    }

    // MARK: - States

    private var analyzingView: some View {
        VStack(spacing: Spacing.medium) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Analyzing \(emails.count) emails for predictions...")
                .font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }

    private var promptView: some View {
        VStack(spacing: Spacing.large) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(colors: [.orange.opacity(0.5), .red.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            Text("Predictive Analysis")
                .font(.system(.title2, design: .rounded)).fontWeight(.bold)
            Text("Predict response urgency, thread outcomes, and security risks across \(emails.count) emails.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            Button { runAnalysis() } label: {
                Label("Run Predictions", systemImage: "sparkles")
                    .font(.headline)
                    .padding(.horizontal, Spacing.large)
                    .padding(.vertical, Spacing.small)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(emails.isEmpty)
            Spacer()
        }
        .padding(Spacing.large)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xSmall) {
                ForEach(PredTab.allCases, id: \.self) { tab in
                    let count = tabCount(tab)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.rawValue)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(.white.opacity(0.3)))
                            }
                        }
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                        .foregroundColor(selectedTab == tab ? .white : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selectedTab == tab ? Capsule().fill(.orange) : Capsule().fill(.orange.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall)
        }
    }

    private func tabCount(_ tab: PredTab) -> Int {
        guard let summary else { return 0 }
        switch tab {
        case .urgency: return summary.urgentEmails.count
        case .threads: return summary.threadPredictions.count
        case .security: return 0
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func tabContent(_ summary: PredictiveEngine.PredictionSummary) -> some View {
        ScrollView {
            VStack(spacing: Spacing.medium) {
                switch selectedTab {
                case .urgency: urgencyTab(summary.urgentEmails)
                case .threads: threadsTab(summary.threadPredictions)
                case .security: securityTab(summary.securityForecast)
                }
            }
            .padding(Spacing.medium)
        }
    }

    // MARK: - Urgency Tab

    private func urgencyTab(_ predictions: [PredictiveEngine.UrgencyPrediction]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            let grouped = Dictionary(grouping: predictions) { $0.urgency }
            let counts = PredictiveEngine.UrgencyLevel.allCases.compactMap { level in
                grouped[level].map { (level, $0.count) }
            }

            HStack(spacing: Spacing.medium) {
                ForEach(counts, id: \.0) { level, count in
                    HStack(spacing: 4) {
                        Circle().fill(urgencyColor(level)).frame(width: 8, height: 8)
                        Text("\(count) \(level.rawValue)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                Spacer()
            }
            .padding(.bottom, Spacing.xSmall)

            if predictions.isEmpty {
                emptyCard("No urgent emails detected", icon: "checkmark.circle")
            } else {
                ForEach(predictions.prefix(30)) { pred in
                    urgencyRow(pred)
                }
            }
        }
    }

    private func urgencyRow(_ pred: PredictiveEngine.UrgencyPrediction) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .fill(urgencyColor(pred.urgency).opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: urgencyIcon(pred.urgency))
                    .font(.system(size: 16))
                    .foregroundColor(urgencyColor(pred.urgency))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(pred.email.headers["Subject"] ?? "No Subject")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(pred.reason)
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                HStack(spacing: Spacing.xSmall) {
                    Text(pred.urgency.rawValue)
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(urgencyColor(pred.urgency)))
                    Text("Score: \(String(format: "%.0f%%", pred.score * 100))")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(pred.email.headers["From"] ?? "").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
        .padding(Spacing.small)
        .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(AppColors.backgroundSecondary))
    }

    // MARK: - Threads Tab

    private func threadsTab(_ predictions: [PredictiveEngine.ThreadPrediction]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if predictions.isEmpty {
                emptyCard("No thread predictions — need threads with 3+ messages", icon: "bubble.left.and.bubble.right")
            } else {
                ForEach(predictions) { pred in
                    threadRow(pred)
                }
            }
        }
    }

    private func threadRow(_ pred: PredictiveEngine.ThreadPrediction) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Image(systemName: outcomeIcon(pred.outcome))
                    .font(.system(size: 14))
                    .foregroundColor(outcomeColor(pred.outcome))
                Text(pred.subject)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(pred.outcome.rawValue)
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(outcomeColor(pred.outcome)))
            }
            Text(pred.detail)
                .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            HStack(spacing: Spacing.xSmall) {
                Text("Confidence: \(String(format: "%.0f%%", pred.confidence * 100))")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary)
                Text(pred.sentimentTrajectory)
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("\(pred.participants.count) participants")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(Spacing.small)
        .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(AppColors.backgroundSecondary))
    }

    // MARK: - Security Tab

    private func securityTab(_ forecast: PredictiveEngine.SecurityForecast) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.small) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .fill(riskColor(forecast.riskLevel).opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 22))
                        .foregroundColor(riskColor(forecast.riskLevel))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overall Risk Level")
                        .font(.caption).foregroundColor(.secondary)
                    Text(forecast.riskLevel)
                        .font(.system(.title3, design: .rounded)).fontWeight(.bold)
                        .foregroundColor(riskColor(forecast.riskLevel))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                forecastRow("Phishing Trend", value: forecast.phishingTrend, icon: "exclamationmark.shield")
                forecastRow("PII Exposure", value: forecast.piiExposureTrend, icon: "person.badge.shield.checkmark")
            }
            .padding(Spacing.medium)
            .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))

            if !forecast.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text("Recommendations")
                        .font(.system(.headline, design: .rounded))
                    ForEach(forecast.recommendations, id: \.self) { rec in
                        HStack(alignment: .top, spacing: Spacing.xSmall) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 11)).foregroundColor(.yellow)
                            Text(rec)
                                .font(.system(size: 12))
                        }
                    }
                }
                .padding(Spacing.medium)
                .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(.yellow.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: CornerRadius.large).strokeBorder(.yellow.opacity(0.15), lineWidth: 0.5))
            }
        }
    }

    private func forecastRow(_ label: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(.secondary)
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func emptyCard(_ message: String, icon: String) -> some View {
        VStack(spacing: Spacing.small) {
            Image(systemName: icon).font(.system(size: 32)).foregroundColor(.green.opacity(0.5))
            Text(message).font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
    }

    private func urgencyColor(_ level: PredictiveEngine.UrgencyLevel) -> Color {
        switch level {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .none: return .gray
        }
    }

    private func urgencyIcon(_ level: PredictiveEngine.UrgencyLevel) -> String {
        switch level {
        case .critical: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.circle.fill"
        case .medium: return "clock.fill"
        case .low: return "arrow.down.circle"
        case .none: return "minus.circle"
        }
    }

    private func outcomeColor(_ outcome: PredictiveEngine.ConversationOutcome) -> Color {
        switch outcome {
        case .reachingConsensus: return .green
        case .atRiskOfConflict: return .red
        case .stalled: return .orange
        case .activeDiscussion: return .blue
        case .resolved: return .mint
        case .unknown: return .gray
        }
    }

    private func outcomeIcon(_ outcome: PredictiveEngine.ConversationOutcome) -> String {
        switch outcome {
        case .reachingConsensus: return "checkmark.circle"
        case .atRiskOfConflict: return "exclamationmark.triangle"
        case .stalled: return "pause.circle"
        case .activeDiscussion: return "bubble.left.and.bubble.right"
        case .resolved: return "checkmark.seal"
        case .unknown: return "questionmark.circle"
        }
    }

    private func riskColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "high", "critical": return .red
        case "medium", "moderate": return .orange
        case "low": return .green
        default: return .secondary
        }
    }

    // MARK: - Actions

    private func runAnalysis() {
        isAnalyzing = true
        let emailsCopy = emails
        Task.detached(priority: .userInitiated) {
            let result = PredictiveEngine.analyze(emails: emailsCopy)
            await MainActor.run {
                summary = result
                isAnalyzing = false
            }
        }
    }
}
