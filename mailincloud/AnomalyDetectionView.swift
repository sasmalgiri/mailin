//
//  AnomalyDetectionView.swift
//  mailin
//
//  Displays anomaly detection results from the statistical engine.
//

import SwiftUI

struct AnomalyDetectionView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?
    @State private var anomalies: [AnomalyDetectionEngine.Anomaly] = []
    @State private var isAnalyzing = false
    @State private var selectedType: AnomalyDetectionEngine.AnomalyType?
    @State private var aiInsights: String?
    @State private var isLoadingAI = false
    @State private var showTutorial = false
    @Environment(\.dismiss) private var envDismiss

    private var filteredAnomalies: [AnomalyDetectionEngine.Anomaly] {
        guard let selected = selectedType else { return anomalies }
        return anomalies.filter { $0.type == selected }
    }

    private var typeCounts: [(type: AnomalyDetectionEngine.AnomalyType, count: Int)] {
        var counts: [AnomalyDetectionEngine.AnomalyType: Int] = [:]
        for anomaly in anomalies {
            counts[anomaly.type, default: 0] += 1
        }
        return AnomalyDetectionEngine.AnomalyType.allCases.compactMap { type in
            guard let count = counts[type], count > 0 else { return nil }
            return (type: type, count: count)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .foregroundColor(AppColors.warning)
                Text("Anomaly Detection")
                    .font(Typography.headline)
                Spacer()
                TutorialHelpButton(showTutorial: $showTutorial)
                if isPresented != nil {
                    Button("Done") { closeSheet() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Spacing.medium)

            Divider()

            if isAnalyzing {
                VStack {
                    Spacer()
                    ProgressView("Scanning for anomalies...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if anomalies.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "checkmark.shield",
                        title: "No Anomalies Found",
                        message: "No unusual patterns detected in the current email archive."
                    )
                    Button("Run Analysis") { analyze() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Spacing.medium)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    // Summary bar
                    summaryBar
                        .padding(Spacing.medium)

                    anomalyExplanationBanner
                        .padding(.horizontal, Spacing.medium)
                        .padding(.bottom, Spacing.small)

                    aiInsightsSection
                        .padding(.horizontal, Spacing.medium)
                        .padding(.bottom, Spacing.small)

                    Divider()

                    // Anomaly list
                    List {
                        ForEach(filteredAnomalies) { anomaly in
                            anomalyRow(anomaly)
                        }
                    }
                }
            }
        }
        .onAppear { analyze() }
        .featureTutorial(.anomalyDetection, key: "anomaly_detection_tutorial_seen", isPresented: $showTutorial)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("\(anomalies.count) anomal\(anomalies.count == 1 ? "y" : "ies") detected")
                .font(Typography.subheadline)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xSmall) {
                    filterChip(label: "All (\(anomalies.count))", isSelected: selectedType == nil) {
                        selectedType = nil
                    }

                    ForEach(typeCounts, id: \.type) { item in
                        filterChip(
                            icon: item.type.icon,
                            label: "\(item.type.rawValue) (\(item.count))",
                            isSelected: selectedType == item.type
                        ) {
                            selectedType = selectedType == item.type ? nil : item.type
                        }
                    }
                }
            }
        }
    }

    private var anomalyExplanationBanner: some View {
        Group {
            if anomalies.isEmpty {
                Label {
                    Text("No anomalies detected — email patterns appear normal across timing, frequency, and content analysis.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(AppColors.success)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.success.opacity(0.1))
                .cornerRadius(CornerRadius.small)
            } else {
                Label {
                    Text("Anomalies indicate unusual patterns in email timing, frequency, or content that deviate from the baseline. Review flagged items — not all anomalies are threats, but they warrant investigation.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(CornerRadius.small)
            }
        }
    }

    private func filterChip(icon: String? = nil, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(label)
            }
            .font(Typography.caption1)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.round)
                    .fill(isSelected ? AppColors.primary.opacity(0.15) : AppColors.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.round)
                    .stroke(isSelected ? AppColors.primary.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Anomaly Row

    private func anomalyRow(_ anomaly: AnomalyDetectionEngine.Anomaly) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: anomaly.type.icon)
                    .foregroundColor(severityColor(anomaly.severity))
                    .frame(width: 20)

                Text(anomaly.title)
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer()

                severityBadge(anomaly.severity)
            }

            // Severity bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppColors.backgroundSecondary)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(severityColor(anomaly.severity))
                        .frame(width: geo.size.width * anomaly.severity, height: 4)
                }
            }
            .frame(height: 4)

            Text(anomaly.detail)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .lineLimit(3)

            Text("\(anomaly.affectedEmails.count) email\(anomaly.affectedEmails.count == 1 ? "" : "s") affected")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.vertical, Spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(severityLabel(anomaly.severity)) anomaly: \(anomaly.title). \(anomaly.detail)")
    }

    private func severityBadge(_ severity: Double) -> some View {
        Text(severityLabel(severity).uppercased())
            .font(Typography.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.xSmall)
            .padding(.vertical, 2)
            .background(severityColor(severity))
            .cornerRadius(CornerRadius.small)
    }

    // MARK: - AI Insights

    private var aiInsightsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Text("AI Analysis")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
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
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(Spacing.small)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }

    private func loadAIInsights() {
        isLoadingAI = true
        let anomalyTypes = typeCounts.map { "\($0.type.rawValue): \($0.count)" }.joined(separator: ", ")
        let context = """
        Anomaly detection found \(anomalies.count) anomalies across \(emails.count) emails. \
        Types: \(anomalyTypes.isEmpty ? "none" : anomalyTypes).
        """
        let emailsCopy = emails
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .security,
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

    // MARK: - Helpers

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private func severityColor(_ severity: Double) -> Color {
        if severity >= 0.7 { return AppColors.error }
        if severity >= 0.4 { return AppColors.warning }
        return AppColors.success
    }

    private func severityLabel(_ severity: Double) -> String {
        if severity >= 0.7 { return "High" }
        if severity >= 0.4 { return "Medium" }
        return "Low"
    }

    private func analyze() {
        isAnalyzing = true
        Task.detached {
            let results = AnomalyDetectionEngine.detectAnomalies(in: emails)
            await MainActor.run {
                anomalies = results
                isAnalyzing = false
            }
        }
    }
}
