import SwiftUI

struct PluginManagerView: View {
    let emails: [MBOXParser.RawEmail]

    @ObservedObject private var manager = PluginManager.shared
    @State private var selectedPluginID: String?
    @State private var isRunningAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if manager.loadedPlugins.isEmpty {
                emptyState
            } else {
                pluginList
            }
        }
        .background(AppColors.backgroundPrimary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.linearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text("Plugin Manager")
                    .font(.system(.title3, design: .rounded)).fontWeight(.bold)
                Text("\(manager.loadedPlugins.count) plugin\(manager.loadedPlugins.count == 1 ? "" : "s") loaded")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !manager.loadedPlugins.isEmpty {
                Button {
                    isRunningAll = true
                    Task {
                        await manager.runAllPlugins(emails: emails)
                        isRunningAll = false
                    }
                } label: {
                    Label("Run All", systemImage: "play.fill")
                        .font(.caption).fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent).tint(.indigo)
                .disabled(isRunningAll || emails.isEmpty)
            }
        }
        .padding(Spacing.medium)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.large) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(colors: [.indigo.opacity(0.5), .purple.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            Text("No Plugins Loaded")
                .font(.system(.title2, design: .rounded)).fontWeight(.bold)
            Text("Plugins extend mailin with custom analysis, export formats, and expert definitions. Register plugins programmatically via PluginManager.shared.register().")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Plugin API").font(.system(size: 13, weight: .semibold))
                protocolRow("analyze(emails:)", "Run custom analysis on emails")
                protocolRow("supportedExportFormats", "Add custom export formats")
                protocolRow("customExpertDefinitions", "Register AI expert personas")
            }
            .padding(Spacing.medium)
            .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
            .frame(maxWidth: 400)

            Spacer()
        }
        .padding(Spacing.large)
    }

    private func protocolRow(_ method: String, _ desc: String) -> some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.indigo)
            Text(method)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.indigo)
            Text("— \(desc)")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    // MARK: - Plugin List

    private var pluginList: some View {
        ScrollView {
            VStack(spacing: Spacing.small) {
                if isRunningAll {
                    HStack(spacing: Spacing.xSmall) {
                        ProgressView().controlSize(.small)
                        Text("Running all plugins on \(emails.count) emails...")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(Spacing.small)
                }

                ForEach(manager.loadedPlugins, id: \.id) { entry in
                    pluginCard(entry)
                }

                let totalFindings = manager.pluginFindings.values.flatMap { $0 }.count
                if totalFindings > 0 {
                    Divider().padding(.vertical, Spacing.xSmall)
                    findingsSummary
                }
            }
            .padding(Spacing.medium)
        }
    }

    private func pluginCard(_ entry: PluginManager.PluginEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("v\(entry.version) · \(entry.description)")
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { manager.setEnabled($0, pluginID: entry.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: Spacing.medium) {
                if let lastRun = entry.lastRunDate {
                    Label("Last: \(lastRun, style: .relative) ago", systemImage: "clock")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                if entry.findingsCount > 0 {
                    Label("\(entry.findingsCount) findings", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
                Spacer()
                Button {
                    Task { _ = await manager.runPlugin(id: entry.id, emails: emails) }
                } label: {
                    Label("Run", systemImage: "play.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!entry.isEnabled || emails.isEmpty)
            }

            if let findings = manager.pluginFindings[entry.id], !findings.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    ForEach(findings.prefix(5), id: \.title) { finding in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(findingSeverityColor(finding.severity))
                                .frame(width: 6, height: 6)
                            Text(finding.title)
                                .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(finding.severity.rawValue)
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                    if findings.count > 5 {
                        Text("+ \(findings.count - 5) more")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                .padding(Spacing.xSmall)
                .background(RoundedRectangle(cornerRadius: CornerRadius.small).fill(AppColors.backgroundPrimary.opacity(0.5)))
            }

            let expertDefs = entry.plugin.customExpertDefinitions
            let exportFmts = entry.plugin.supportedExportFormats
            if !expertDefs.isEmpty || !exportFmts.isEmpty {
                HStack(spacing: Spacing.xSmall) {
                    if !expertDefs.isEmpty {
                        Label("\(expertDefs.count) expert\(expertDefs.count == 1 ? "" : "s")", systemImage: "person.crop.rectangle.stack")
                            .font(.system(size: 9)).foregroundColor(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.purple.opacity(0.08)))
                    }
                    if !exportFmts.isEmpty {
                        Label("\(exportFmts.count) format\(exportFmts.count == 1 ? "" : "s")", systemImage: "doc.text")
                            .font(.system(size: 9)).foregroundColor(.blue)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.08)))
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
    }

    // MARK: - Findings Summary

    private var findingsSummary: some View {
        let allFindings = manager.pluginFindings.values.flatMap { $0 }
        let critical = allFindings.filter { $0.severity == .critical }.count
        let warning = allFindings.filter { $0.severity == .warning }.count
        let info = allFindings.filter { $0.severity == .info }.count

        return VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("All Plugin Findings").font(.system(.headline, design: .rounded))
            HStack(spacing: Spacing.medium) {
                findingBadge("Critical", count: critical, color: .red)
                findingBadge("Warning", count: warning, color: .orange)
                findingBadge("Info", count: info, color: .blue)
                Spacer()
                Text("\(allFindings.count) total")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(Spacing.medium)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(AppColors.backgroundSecondary))
    }

    private func findingBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(count > 0 ? color : .secondary)
        }
    }

    private func findingSeverityColor(_ severity: MailinPluginFinding.Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
