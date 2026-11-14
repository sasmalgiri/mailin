@testable import ArchiveCore
import SwiftUI

struct SmartAlertsView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?
    @State private var alerts: [SmartAlert] = []
    @State private var isAnalyzing = false
    @State private var showTutorial = false
    @State private var expandedAlertID: UUID?
    @Environment(\.dismiss) private var envDismiss
    // §3-A1: whole-archive alerts when the 3.0 engine is on.
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?
    @Environment(\.archiveScope) private var scope
    @State private var hydrated: [UUID: MBOXParser.RawEmail] = [:]
    @State private var v3Note: String?
    private var v3: Bool { modules?.isOn(.v3AlertsAnomalies) ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(AppColors.warning)
                Text("Smart Alerts")
                    .font(Typography.headline)
                if let v3Note {
                    Text(v3Note).font(Typography.caption2).foregroundColor(AppColors.secondary)
                }
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
                    ProgressView("Analyzing emails for patterns...")
                        .font(Typography.callout)
                    Spacer()
                }
            } else if alerts.isEmpty {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "checkmark.shield",
                        title: String(localized: "No Alerts"),
                        message: String(localized: "No suspicious patterns detected in the current archive.")
                    )
                    Button("Run Analysis") { analyze() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Spacing.medium)
                    Spacer()
                }
            } else {
                Label {
                    Text("Smart Alerts monitor your archive for keyword matches, unusual patterns, and threshold triggers. Tap an alert to see affected emails.")
                        .font(Typography.caption1)
                } icon: {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.orange)
                }
                .padding(Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(CornerRadius.small)
                .padding(.horizontal, Spacing.medium)
                .padding(.top, Spacing.small)

                List {
                    ForEach(alerts) { alert in
                        alertRow(alert)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedAlertID = expandedAlertID == alert.id ? nil : alert.id
                                }
                            }

                        if expandedAlertID == alert.id {
                            affectedEmailsList(alert)
                        }
                    }
                }
            }
        }
        .onAppear { analyze() }
        .featureTutorial(.smartAlerts, key: "smart_alerts_tutorial_seen", isPresented: $showTutorial)
        #if os(macOS)
        .toolWindowFrame()
        #endif
    }

    private func closeSheet() {
        if let isPresented {
            isPresented.wrappedValue = false
        } else {
            envDismiss()
        }
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
                Image(systemName: expandedAlertID == alert.id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
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

    private func affectedEmailsList(_ alert: SmartAlert) -> some View {
        let affected: [MBOXParser.RawEmail] = v3
            ? alert.emailIDs.prefix(20).compactMap { id in hydrated[id] ?? emails.first(where: { $0.id == id }) }
            : Array(emails.filter { alert.emailIDs.contains($0.id) }.prefix(20))
        return ForEach(affected, id: \.id) { email in
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Text(email.headers["Subject"] ?? "(No Subject)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(email.headers["Date"]?.prefix(16) ?? "")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 24)
            .padding(.vertical, 1)
        }
    }

    private func severityColor(_ severity: SmartAlertSeverity) -> Color {
        switch severity {
        case .high: return AppColors.error
        case .medium: return AppColors.warning
        case .low: return AppColors.info
        }
    }

    /// `previousEngine`: run the pre-3.0 path (switch off, or §3-M3 fallback).
    private func analyze(previousEngine: Bool = false) {
        if v3 && !previousEngine {
            isAnalyzing = true
            Task { @MainActor in
                defer { isAnalyzing = false }
                do {
                    let r = try await SmartNotificationManager().analyzeForAlertsWholeArchive(query: scope.query)
                    alerts = r.alerts
                    // First 20 affected emails of every alert (what the rows show).
                    let ids = Array(Set(r.alerts.flatMap { $0.emailIDs.prefix(20) }))
                    var map: [UUID: MBOXParser.RawEmail] = [:]
                    for start in stride(from: 0, to: ids.count, by: 200) {
                        for e in (try? await ArchiveDataService.shared.fullEmails(ids: Array(ids[start..<min(start + 200, ids.count)]))) ?? [] {
                            map[e.id] = e
                        }
                    }
                    hydrated = map
                    v3Note = r.receipt.coverageLine
                } catch is CancellationError {
                    v3Note = nil
                } catch {
                    v3Note = EngineGuard.fellBack(.v3AlertsAnomalies, error: error)
                    analyze(previousEngine: true)
                }
            }
            return
        }
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
