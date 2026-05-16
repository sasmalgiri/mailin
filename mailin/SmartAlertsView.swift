import SwiftUI

struct SmartAlertsView: View {
    let emails: [MBOXParser.RawEmail]
    @State private var alerts: [SmartAlert] = []
    @State private var isAnalyzing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(AppColors.warning)
                Text("Smart Alerts")
                    .font(Typography.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Spacing.medium)

            Divider()

            if isAnalyzing {
                VStack {
                    Spacer()
                    ProgressView("Analyzing emails for patterns...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if alerts.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "checkmark.shield",
                        title: "No Alerts",
                        message: "No suspicious patterns detected in the current archive."
                    )
                    Button("Run Analysis") { analyze() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Spacing.medium)
                    Spacer()
                }
            } else {
                List {
                    ForEach(alerts) { alert in
                        alertRow(alert)
                    }
                }
            }
        }
        .onAppear { analyze() }
        #if os(macOS)
        .frame(minWidth: 550, minHeight: 450)
        #endif
    }

    private func alertRow(_ alert: SmartAlert) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: alert.type.icon)
                    .foregroundColor(severityColor(alert.severity))
                Text(alert.title)
                    .font(Typography.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(alert.severity.rawValue.uppercased())
                    .font(Typography.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(severityColor(alert.severity))
                    .cornerRadius(CornerRadius.small)
            }
            Text(alert.message)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Text("\(alert.emailIDs.count) email\(alert.emailIDs.count == 1 ? "" : "s") affected")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.vertical, Spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.severity.rawValue) alert: \(alert.title), \(alert.message)")
    }

    private func severityColor(_ severity: SmartAlertSeverity) -> Color {
        switch severity {
        case .high: return AppColors.error
        case .medium: return AppColors.warning
        case .low: return AppColors.info
        }
    }

    private func analyze() {
        isAnalyzing = true
        let emailsCopy = emails
        Task {
            let manager = SmartNotificationManager()
            let results = manager.analyzeForAlerts(emails: emailsCopy)
            alerts = results.sorted { $0.severity > $1.severity }
            isAnalyzing = false
        }
    }
}
