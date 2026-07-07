import SwiftUI

struct BackgroundFindingsView: View {
    let emails: [MBOXParser.RawEmail]

    @ObservedObject private var manager = BackgroundAnalysisManager.shared
    @State private var selectedCategory: String?
    @State private var showTutorial = false

    private var categories: [String] {
        Array(Set(manager.lastRunFindings.map(\.category))).sorted()
    }

    private var filteredFindings: [BackgroundAnalysisManager.BackgroundFinding] {
        let findings = manager.lastRunFindings.sorted { $0.severity > $1.severity }
        guard let cat = selectedCategory else { return findings }
        return findings.filter { $0.category == cat }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if manager.isRunning {
                runningView
            } else if manager.lastRunFindings.isEmpty {
                emptyState
            } else {
                categoryBar
                findingsList
            }
        }
        .background(AppColors.backgroundPrimary)
        .featureTutorial(.backgroundFindings, key: "background_findings_tutorial_seen", isPresented: $showTutorial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.linearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text("Background Findings")
                    .font(.system(.title3, design: .rounded)).fontWeight(.bold)
                if let lastRun = manager.lastRunDate {
                    Text("Last scan: \(lastRun, style: .relative) ago")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("No scans run yet")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            TutorialHelpButton(showTutorial: $showTutorial)
            Button {
                Task { await manager.runAnalysis() }
            } label: {
                Label("Scan Now", systemImage: "play.fill")
                    .font(.caption).fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(manager.isRunning || emails.isEmpty)
        }
        .padding(Spacing.medium)
    }

    // MARK: - States

    private var runningView: some View {
        VStack(spacing: Spacing.medium) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scanning \(emails.count) emails...")
                .font(.subheadline).foregroundColor(.secondary)
            Text("Checking anomalies, phishing, PII, sentiment trends")
                .font(.caption).foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.large) {
            Spacer()
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(colors: [.green.opacity(0.5), .blue.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            Text("No Findings Yet")
                .font(.system(.title2, design: .rounded)).fontWeight(.bold)
            Text(emails.isEmpty
                 ? "Import emails first, then run a background scan."
                 : "Run a background scan to detect anomalies, phishing, PII exposure, and sentiment shifts.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if !emails.isEmpty {
                Button {
                    Task { await manager.runAnalysis() }
                } label: {
                    Label("Run First Scan", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, Spacing.large)
                        .padding(.vertical, Spacing.small)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            Spacer()
        }
        .padding(Spacing.large)
    }

    // MARK: - Category Bar

    private var categoryBar: some View {
        VStack(spacing: Spacing.xSmall) {
            summaryBar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xSmall) {
                    categoryChip(label: "All", category: nil, count: manager.lastRunFindings.count)
                    ForEach(categories, id: \.self) { cat in
                        let count = manager.lastRunFindings.filter { $0.category == cat }.count
                        categoryChip(label: displayName(for: cat), category: cat, count: count)
                    }
                }
                .padding(.horizontal, Spacing.medium)
            }
        }
        .padding(.vertical, Spacing.xSmall)
    }

    private var summaryBar: some View {
        let high = manager.lastRunFindings.filter { $0.severity >= 0.7 }.count
        let medium = manager.lastRunFindings.filter { $0.severity >= 0.4 && $0.severity < 0.7 }.count
        let low = manager.lastRunFindings.filter { $0.severity < 0.4 }.count

        return HStack(spacing: Spacing.medium) {
            severityBadge("High", count: high, color: .red)
            severityBadge("Medium", count: medium, color: .orange)
            severityBadge("Low", count: low, color: .green)
            Spacer()
            Text("\(manager.lastRunFindings.count) total findings")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, Spacing.medium)
    }

    private func severityBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(count > 0 ? color : .secondary)
        }
    }

    private func categoryChip(label: String, category: String?, count: Int) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedCategory = category }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconForCategory(category))
                    .font(.system(size: 10))
                Text("\(label) (\(count))")
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Capsule().fill(.orange) : Capsule().fill(.orange.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Findings List

    private var findingsList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.small) {
                ForEach(filteredFindings) { finding in
                    findingRow(finding)
                }
            }
            .padding(Spacing.medium)
        }
    }

    private func findingRow(_ finding: BackgroundAnalysisManager.BackgroundFinding) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .fill(severityColor(finding.severity).opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: iconForCategory(finding.category))
                    .font(.system(size: 16))
                    .foregroundColor(severityColor(finding.severity))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer()
                    severityLabel(finding.severity)
                }
                Text(finding.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                HStack(spacing: Spacing.xSmall) {
                    Text(displayName(for: finding.category))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(AppColors.backgroundSecondary))
                    Text(finding.timestamp, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .padding(Spacing.small)
        .background(RoundedRectangle(cornerRadius: CornerRadius.medium).fill(AppColors.backgroundSecondary))
    }

    // MARK: - Helpers

    private func severityLabel(_ severity: Double) -> some View {
        let label = severity >= 0.7 ? "High" : severity >= 0.4 ? "Medium" : "Low"
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(severityColor(severity)))
    }

    private func severityColor(_ severity: Double) -> Color {
        severity >= 0.7 ? .red : severity >= 0.4 ? .orange : .green
    }

    private func displayName(for category: String?) -> String {
        guard let cat = category else { return "All" }
        switch cat {
        case "anomaly": return "Anomalies"
        case "phishing": return "Phishing"
        case "pii": return "PII Exposure"
        case "sentiment": return "Sentiment"
        case "domain_burst": return "Domain Burst"
        default: return cat.capitalized
        }
    }

    private func iconForCategory(_ category: String?) -> String {
        guard let cat = category else { return "list.bullet" }
        switch cat {
        case "anomaly": return "waveform.path.ecg"
        case "phishing": return "exclamationmark.shield.fill"
        case "pii": return "person.badge.shield.checkmark.fill"
        case "sentiment": return "heart.fill"
        case "domain_burst": return "globe.badge.chevron.backward"
        default: return "questionmark.circle"
        }
    }
}
