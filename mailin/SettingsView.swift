//
//  SettingsView.swift
//  mailin
//
//  Apple-grade Settings interface following Human Interface Guidelines
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @AppStorage("autoDetectSender") private var autoDetectSender = true
    @AppStorage("showInlineImages") private var showInlineImages = true
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @AppStorage("emailListDensity") private var emailListDensity = "comfortable"
    @AppStorage("showEmailPreviews") private var showEmailPreviews = true
    @AppStorage("autoAdvanceAfterTag") private var autoAdvanceAfterTag = true
    @AppStorage("hasConsentedToCloudAI") private var hasConsentedToCloudAI = false
    @State private var openAIAPIKey = KeychainHelper.load(key: "openAIAPIKey")
    @AppStorage("openAIModel") private var openAIModel = "gpt-4o-mini"
    @AppStorage("openAIEndpoint") private var openAIEndpoint = "https://api.openai.com/v1"
    @AppStorage("customModelName") private var customModelName = ""
    @State private var savedDataCleared = false
    @State private var showClearConfirmation = false
    @State private var showClearTempConfirmation = false
    @State private var showResetSettingsConfirmation = false
    @State private var showClearForensicConfirmation = false
    @State private var tempFilesCleared = false
    @State private var settingsReset = false
    @State private var forensicDataCleared = false
    
    var body: some View {
        TabView {
            profileSettings
                .tabItem {
                    Label("Profile", systemImage: personaManager.selectedPersona.icon)
                }

            generalSettings
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            parsingSettings
                .tabItem {
                    Label("Parsing", systemImage: "envelope.open")
                }
            
            displaySettings
                .tabItem {
                    Label("Display", systemImage: "eyeglasses")
                }
            
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }

            forensicSettings
                .tabItem {
                    Label("Forensic", systemImage: "shield.checkered")
                }
        }
        .frame(minWidth: 400, idealWidth: 540, minHeight: 380, idealHeight: 520)
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
    }
    
    // MARK: - Profile / Persona Settings
    private var profileSettings: some View {
        Form {
            Section {
                ForEach(PersonaManager.Persona.allCases, id: \.rawValue) { persona in
                    Button {
                        personaManager.selectedPersona = persona
                    } label: {
                        HStack(spacing: Spacing.small) {
                            Image(systemName: persona.icon)
                                .font(.system(size: 20))
                                .foregroundColor(persona.accentColor)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(persona.displayName)
                                    .font(Typography.headline)
                                    .foregroundColor(.primary)
                                Text(persona.tagline)
                                    .font(Typography.caption1)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if personaManager.selectedPersona == persona {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(persona.accentColor)
                                    .font(.system(size: 16))
                            }
                        }
                        .padding(.vertical, Spacing.xxSmall)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Choose Your Role")
                    .font(.headline)
            } footer: {
                Text("Your role customizes the interface: sidebar layout, quick filters, export options, and AI suggestions are tailored to your workflow.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Current Profile")
                    Spacer()
                    Label(personaManager.selectedPersona.displayName, systemImage: personaManager.selectedPersona.icon)
                        .foregroundColor(personaManager.selectedPersona.accentColor)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Default Density")
                    Spacer()
                    Text(personaManager.config.defaultDensity.capitalized)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Forensic Mode")
                    Spacer()
                    Text(personaManager.config.showForensicByDefault ? "Auto-enabled" : "Manual")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("AI Features")
                    Spacer()
                    Text(personaManager.config.enableAIByDefault ? "Enabled" : "On Request")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Active Configuration")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - General Settings
    private var generalSettings: some View {
        Form {
            Section {
                TextField("Default Email Address", text: $defaultSenderEmail)
                    .help("Your primary email address for automatic filtering")
                    .accessibilityLabel("Default email address")
                    .accessibilityHint("Your primary email address for automatic filtering")

                Toggle("Auto-detect sender from emails", isOn: $autoDetectSender)
                    .help("Automatically identify your email from the most common sender")
                    .accessibilityLabel("Auto-detect sender")
                    .accessibilityHint("Automatically identify your email from the most common sender")
            } header: {
                Text("Email Identity")
                    .font(.headline)
            }

        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Parsing Settings
    private var parsingSettings: some View {
        Form {
            Section {
                Toggle("Enable inline images", isOn: $showInlineImages)
                    .help("Display embedded images in HTML emails")
            } header: {
                Text("Content Processing")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Display Settings
    private var displaySettings: some View {
        Form {
            Section {
                Picker("Email List Density", selection: $emailListDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Spacious").tag("spacious")
                }
                .help("Controls the spacing between emails in the list")

                Toggle("Show email previews", isOn: $showEmailPreviews)
                    .help("Show a snippet of the email body in the list view")
            } header: {
                Text("Email List")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Advanced Settings
    private var advancedSettings: some View {
        Form {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    if storeManager.isPremium {
                        Label("Pro", systemImage: "crown.fill")
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                    } else {
                        Text("Free")
                            .foregroundColor(.secondary)
                    }
                }

                if !storeManager.isPremium {
                    Button("Upgrade to Pro") {
                        storeManager.showPaywall = true
                    }
                }

                Button("Manage Subscription") {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityLabel("Manage subscription")
                .accessibilityHint("Opens App Store subscription management")

                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
                .accessibilityLabel("Restore purchases")
            } header: {
                Text("Subscription")
                    .font(.headline)
            } footer: {
                Text("Manage, cancel, or change your subscription in the App Store.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Enable AI features", isOn: $enableAIFeatures)
                    .help("Show AI assistant and analysis features")
            } header: {
                Text("AI Assistant")
                    .font(.headline)
            }

            Section {
                SecureField("API Key", text: $openAIAPIKey)
                    .help("Your OpenAI API key (starts with sk-). Stored securely in your Mac's Keychain.")
                    .accessibilityLabel("OpenAI API key")
                    .onChange(of: openAIAPIKey) { _, newValue in
                        KeychainHelper.save(key: "openAIAPIKey", value: newValue)
                    }

                Picker("Model", selection: $openAIModel) {
                    Text("GPT-4o Mini (fast, affordable)").tag("gpt-4o-mini")
                    Text("GPT-4o (best quality)").tag("gpt-4o")
                    Text("Custom model").tag("custom")
                }

                if openAIModel == "custom" {
                    TextField("Custom model name", text: $customModelName)
                        .help("e.g., gpt-3.5-turbo, llama-3, or any model your endpoint supports")
                }

                TextField("API Endpoint", text: $openAIEndpoint)
                    .help("Default: https://api.openai.com/v1 — Change for Ollama, LM Studio, or other OpenAI-compatible servers")
                    .font(.system(.body, design: .monospaced))

                Toggle("I consent to sending email data to this API provider", isOn: $hasConsentedToCloudAI)
                    .help("Required before Cloud AI can be used. You can revoke this at any time.")
                    .accessibilityLabel("Cloud AI data sharing consent")

                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("When using a cloud API, email data is sent to the provider's servers. Use a local endpoint (Ollama, LM Studio) to keep data on-device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Spacing.xxSmall)
            } header: {
                Text("Cloud AI (Optional)")
                    .font(.headline)
            } footer: {
                Text("Bring your own API key for OpenAI, or use any OpenAI-compatible endpoint (Ollama, LM Studio, etc.)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Clear saved email data") {
                    showClearConfirmation = true
                }
                .disabled(savedDataCleared || !EmailPersistence.hasSavedData)
                .alert("Clear Saved Data", isPresented: $showClearConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        EmailPersistence.clear()
                        savedDataCleared = true
                        NotificationCenter.default.post(name: .dataClearedByUser, object: nil)
                    }
                } message: {
                    Text("This will permanently delete all saved email data. This action cannot be undone.")
                }

                if savedDataCleared {
                    Text("Saved data cleared successfully.")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Button("Clear all temporary files") {
                    showClearTempConfirmation = true
                }
                .alert("Clear Temporary Files", isPresented: $showClearTempConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        clearTempFiles()
                        tempFilesCleared = true
                    }
                } message: {
                    Text("This will delete all temporary files created by mailin. This is safe but cannot be undone.")
                }

                if tempFilesCleared {
                    Text("Temporary files cleared.")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Button("Reset all settings") {
                    showResetSettingsConfirmation = true
                }
                .foregroundColor(.red)
                .alert("Reset All Settings", isPresented: $showResetSettingsConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset", role: .destructive) {
                        resetSettings()
                        settingsReset = true
                    }
                } message: {
                    Text("This will restore all settings to their defaults. Your email data will not be affected.")
                }

                if settingsReset {
                    Text("Settings restored to defaults.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } header: {
                Text("Maintenance")
                    .font(.headline)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("About")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Forensic Settings
    private var forensicSettings: some View {
        Form {
            Section {
                Toggle("Enable Forensic Mode", isOn: $forensicManager.isEnabled)
                    .help("Activates evidence integrity features: hash verification, audit logging, evidence tagging, and disables cloud AI")
                    .accessibilityLabel("Forensic mode")

                Toggle("Auto-advance after tagging", isOn: $autoAdvanceAfterTag)
                    .help("Automatically move to the next unreviewed email after applying an evidence tag")
                    .accessibilityLabel("Auto-advance after tagging")

                if forensicManager.isEnabled {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                        Text("Active — All analysis on-device. Cloud AI disabled.")
                            .font(Typography.caption1)
                            .foregroundColor(.green)
                    }
                }
            } header: {
                Text("Forensic Mode")
                    .font(.headline)
            } footer: {
                Text("Forensic mode enables hash verification of source files, a full audit log, evidence tagging, and blocks cloud AI to maintain chain of custody.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                TextField("Case Number", text: $forensicManager.caseNumber)
                    .help("Identifier for this forensic case (e.g., CASE-2026-0042)")
                    .accessibilityLabel("Case number")

                TextField("Examiner Name", text: $forensicManager.examinerName)
                    .help("Name of the forensic examiner")
                    .accessibilityLabel("Examiner name")

                TextField("Organization", text: $forensicManager.organization)
                    .help("Examiner's organization or agency")
                    .accessibilityLabel("Organization")
            } header: {
                Text("Case Information")
                    .font(.headline)
            } footer: {
                Text("This information is included in forensic exports and the audit log.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                if !forensicManager.sourceFileHashes.isEmpty {
                    ForEach(forensicManager.sourceFileHashes) { hash in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hash.filename)
                                .font(Typography.callout)
                                .fontWeight(.medium)
                            Text("SHA-256: \(hash.sha256.prefix(32))...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("SHA-1: \(hash.sha1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("MD5: \(hash.md5)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("\(formatFileSize(hash.fileSize)) — Imported \(hash.importDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(Typography.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    Text("No source files imported yet.")
                        .font(Typography.caption1)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Source File Integrity (MD5 + SHA-1 + SHA-256)")
                    .font(.headline)
            }

            Section {
                HStack {
                    Text("Audit log integrity")
                    Spacer()
                    switch forensicManager.integrityStatus {
                    case .verified:
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    case .tampered(let detail):
                        Label("TAMPERED", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                            .help(detail)
                    case .noData:
                        Text("No entries")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    case .unknown:
                        Text("Not checked")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Button("Verify Audit Log Integrity") {
                    _ = forensicManager.verifyAuditLogIntegrity()
                }
                .disabled(forensicManager.auditLog.isEmpty)

                HStack {
                    Text("Audit log entries")
                    Spacer()
                    Text("\(forensicManager.auditLog.count)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Per-email hashes stored")
                    Spacer()
                    Text("\(forensicManager.perEmailHashes.count)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Tagged emails")
                    Spacer()
                    Text("\(forensicManager.evidenceTags.count)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Annotations")
                    Spacer()
                    Text("\(forensicManager.annotations.count)")
                        .foregroundColor(.secondary)
                }

                Button("Clear all forensic data") {
                    showClearForensicConfirmation = true
                }
                .foregroundColor(.red)
                .alert("Clear Forensic Data", isPresented: $showClearForensicConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        forensicManager.clearForensicData()
                        forensicDataCleared = true
                    }
                } message: {
                    Text("This will permanently delete the audit log, file hashes, and all evidence tags. This cannot be undone.")
                }

                if forensicDataCleared {
                    Text("Forensic data cleared.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } header: {
                Text("Forensic Data")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f KB", kb)
    }

    // MARK: - Actions
    private func clearTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("mailin") }
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }
    
    private func resetSettings() {
        defaultSenderEmail = ""
        autoDetectSender = true
        showInlineImages = true
        enableAIFeatures = true
        emailListDensity = "comfortable"
        showEmailPreviews = true
        openAIAPIKey = ""
        KeychainHelper.delete(key: "openAIAPIKey")
        openAIModel = "gpt-4o-mini"
        openAIEndpoint = "https://api.openai.com/v1"
        customModelName = ""
    }
}

#Preview {
    SettingsView()
        .environmentObject(StoreManager())
}
