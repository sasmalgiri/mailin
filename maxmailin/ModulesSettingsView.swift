//
//  ModulesSettingsView.swift
//  mailin
//
//  Settings ▸ Modules — the only place the four pages are switched on and off
//  (v3.0 §3.3, directive §1). One status card per page, showing what is
//  running, what is kept when the page is switched off, and whether anything
//  inside it needs a purchase. Enabling a page here never implies it is free,
//  and a page an organization has disabled is shown as locked, not as off.
//

import SwiftUI

struct ModulesSettingsView: View {
    @Environment(ModuleRegistry.self) private var modules
    @EnvironmentObject private var storeManager: StoreManager

    /// The page the user is about to switch off, driving the retention dialog.
    @State private var pendingDisable: AppModule?
    @State private var enableError: String?
    /// Which page's capability matrix is open, and the all-pages variant.
    @State private var matrixScope: AppModule?
    @State private var showFullMatrix = false

    var body: some View {
        Form {
            Section {
                ForEach(AppModule.allCases, id: \.rawValue) { module in
                    ModuleCard(
                        module: module,
                        activation: modules.activation(module),
                        runningJobs: modules.jobs.jobs(for: module).count,
                        needsProfessional: Self.needsProfessional(module),
                        hasProfessional: storeManager.isProfessional,
                        onEnable: { enable(module) },
                        onDisable: { pendingDisable = module },
                        onUpgrade: { storeManager.showPaywall = true }
                    )
                }
            } header: {
                Text("Pages")
                    .font(.headline)
            } footer: {
                Text("""
                    Archive is always available. AI Insights, Professional Workflows and \
                    Live Mail stay completely off — no background work, no indexing, no \
                    network — until you switch them on here. Switching one off stops its \
                    work and hides its page; your saved work is kept.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // The level below pages: every capability, one switch each.
            // Presented as its own section rather than inline per page,
            // because the list is long and the page cards above are the
            // decision most users make.
            Section {
                ForEach(AppModule.allCases, id: \.rawValue) { module in
                    let all = Capability.all(for: module)
                    if !all.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(module.displayName)
                                Text("\(modules.activeCapabilities(of: module).count) of \(all.count) running")
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                            }
                            Spacer()
                            Button("Features…") { matrixScope = module }
                                .controlSize(.small)
                        }
                    }
                }
                Button("Show the full matrix…") { showFullMatrix = true }
                    .controlSize(.small)
            } header: {
                Text("Features")
                    .font(.headline)
            } footer: {
                Text("""
                    Each capability can be switched off on its own without giving up its page. \
                    Anything switched off is hidden or stopped — never deleted: cases, \
                    documents, holds, audit entries and imported mail all stay exactly as \
                    they are and return unchanged when it is switched back on. New engines \
                    ship switched off, so an update never changes how your archive behaves \
                    until you ask it to.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !modules.jobs.isIdle {
                Section {
                    ForEach(modules.jobs.entries) { entry in
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label)
                                Text(entry.module.displayName)
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                            }
                            Spacer()
                            Button("Stop") { entry.cancel() }
                                .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Running now")
                        .font(.headline)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $matrixScope) { module in
            CapabilityMatrixView(scope: module)
        }
        .sheet(isPresented: $showFullMatrix) {
            CapabilityMatrixView(scope: nil)
        }
        .confirmationDialog(
            pendingDisable.map { "Turn off \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { pendingDisable != nil },
                                 set: { if !$0 { pendingDisable = nil } }),
            titleVisibility: .visible
        ) {
            if let module = pendingDisable {
                Button("Turn off and keep my work") {
                    modules.disable(module, retention: .keepArtifacts)
                    pendingDisable = nil
                }
                Button("Cancel", role: .cancel) { pendingDisable = nil }
            }
        } message: {
            if let module = pendingDisable {
                Text(Self.disableExplanation(for: module))
            }
        }
        .alert("Cannot turn this on", isPresented: Binding(
            get: { enableError != nil },
            set: { if !$0 { enableError = nil } }
        )) {
            Button("OK") { enableError = nil }
        } message: {
            Text(enableError ?? "")
        }
    }

    private func enable(_ module: AppModule) {
        do {
            try modules.enable(module)
        } catch {
            enableError = error.localizedDescription
        }
    }

    /// Pages whose contents are gated by the Professional tier. The page can
    /// still be switched on; the tier gate lives inside the features, so the
    /// card states the requirement rather than silently unlocking anything.
    private static func needsProfessional(_ module: AppModule) -> Bool {
        switch module {
        case .archive, .aiInsights, .liveMail: return false
        case .professional: return true
        }
    }

    /// Exactly what is stopped and what is kept, per page. Disabling a page must
    /// never destroy evidence, cases or holds (§3.3 R4).
    private static func disableExplanation(for module: AppModule) -> String {
        switch module {
        case .archive:
            return "Archive cannot be turned off."
        case .aiInsights:
            return """
                Running analysis and scheduled digests stop, and the model is unloaded. \
                Saved summaries and reports are kept, and your archive is untouched.
                """
        case .professional:
            return """
                Running workflows pause and the page is hidden. Cases, custodians, legal \
                holds, numbered documents and the audit chain are all kept — nothing is \
                deleted and no hold is lifted. The audit chain records that it resumes \
                when you turn this back on.
                """
        case .liveMail:
            return """
                Syncing and sending stop and accounts are disconnected locally. Nothing is \
                deleted from your mail server. Downloaded mail stays in this app's cache \
                until you remove an account explicitly.
                """
        }
    }
}

#if DEBUG
#Preview("Modules — Page 1 only") {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("preview-modules-\(UUID().uuidString).json")
    return ModulesSettingsView()
        .environment(ModuleRegistry(store: ModuleStateStore(url: url),
                                    excludedByBuild: [], trapsOnMisuse: false))
        .environmentObject(StoreManager())
        .frame(width: 560, height: 520)
}
#endif

// MARK: - One page's card

private struct ModuleCard: View {
    let module: AppModule
    let activation: ModuleActivation
    let runningJobs: Int
    let needsProfessional: Bool
    let hasProfessional: Bool
    let onEnable: () -> Void
    let onDisable: () -> Void
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.displayName)
                        .font(Typography.headline)
                    Text(purpose)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                Spacer()
                statusControl
            }

            HStack(spacing: Spacing.xSmall) {
                // Archive's control already reads "Always on"; repeating it in
                // the status line says nothing.
                if module.isOptional {
                    Text(statusLabel)
                        .font(Typography.caption2)
                        .foregroundColor(statusColor)
                }
                if runningJobs > 0 {
                    Text("· \(runningJobs) running")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
                if needsProfessional && !hasProfessional {
                    Text("· some features need Professional")
                        .font(Typography.caption2)
                        .foregroundColor(.purple)
                    Button("Upgrade", action: onUpgrade)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, Spacing.xxSmall)
    }

    @ViewBuilder
    private var statusControl: some View {
        switch activation {
        case .unavailable:
            Image(systemName: "lock.fill")
                .foregroundColor(AppColors.secondary)
                .help(statusLabel)
        case .disabled:
            Button("Turn On", action: onEnable)
                .controlSize(.small)
        case .active, .enabledNoAccounts, .paused, .error:
            if module.isOptional {
                Button("Turn Off", action: onDisable)
                    .controlSize(.small)
            } else {
                Text("Always on")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
        }
    }

    private var statusLabel: String {
        switch activation {
        case .unavailable(let reason): return reason.prefix(1).capitalized + reason.dropFirst()
        case .disabled: return "Off — nothing from this page is running"
        case .enabledNoAccounts: return "On — no account added yet"
        case .active: return module.isOptional ? "On" : "Always available"
        case .paused(let reason): return "Paused — \(reason)"
        case .error(let message): return "Error — \(message)"
        }
    }

    private var statusColor: Color {
        switch activation {
        case .active, .enabledNoAccounts: return .green
        case .disabled, .unavailable: return AppColors.secondary
        case .paused: return .orange
        case .error: return .red
        }
    }

    private var icon: String {
        switch module {
        case .archive: return "archivebox"
        case .aiInsights: return "sparkles"
        case .professional: return "briefcase"
        case .liveMail: return "envelope.badge"
        }
    }

    private var iconColor: Color {
        activation.mayRunWork ? .accentColor : AppColors.secondary
    }

    private var purpose: String {
        switch module {
        case .archive:
            return "Import, search and export your mail. Always available, fully offline."
        case .aiInsights:
            return "Ask questions, summarise and build reports with citations back to originals."
        case .professional:
            return "Case intake, review, production and audit workflows."
        case .liveMail:
            return "Connect mail accounts to send and receive. Kept separate from your archive."
        }
    }
}
