//
//  SettingsView.swift
//  mailin
//
//  Apple-grade Settings interface following Human Interface Guidelines
//

import SwiftUI
import TipKit

struct SettingsView: View {
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @ObservedObject private var collabManager = CollaborationManager.shared
    @ObservedObject private var iCloudSync = iCloudSyncManager.shared
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @AppStorage("autoDetectSender") private var autoDetectSender = true
    @AppStorage("showInlineImages") private var showInlineImages = true
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @AppStorage("emailListDensity") private var emailListDensity = "comfortable"
    @AppStorage("showEmailPreviews") private var showEmailPreviews = true
    @AppStorage("autoAdvanceAfterTag") private var autoAdvanceAfterTag = true
    @AppStorage("hasConsentedToCloudAI") private var hasConsentedToCloudAI = false
    @AppStorage("customModelName") private var customModelName = ""
    @State private var savedDataCleared = false
    @State private var showClearConfirmation = false
    @State private var showClearTempConfirmation = false
    @State private var showResetSettingsConfirmation = false
    @State private var showClearForensicConfirmation = false
    @State private var tempFilesCleared = false
    @State private var settingsReset = false
    @State private var forensicDataCleared = false
    @State private var showDeleteAllConfirmation = false
    @State private var allDataDeleted = false
    @ObservedObject private var compliance = LegalComplianceManager.shared
    #if os(iOS)
    @State private var showFolderPicker = false
    #endif

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

            iCloudSyncSettings
                .tabItem {
                    Label("Sync", systemImage: "icloud")
                }

            collaborationSettings
                .tabItem {
                    Label("Collaboration", systemImage: "person.2")
                }

            helpAndTipsSettings
                .tabItem {
                    Label("Help", systemImage: "questionmark.circle")
                }

        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 540, minHeight: 380, idealHeight: 520)
        #endif
    }
    
    // MARK: - Profile / Persona Settings
    private var profileSettings: some View {
        Form {
            Section {
                ForEach(PersonaManager.Persona.allCases, id: \.rawValue) { persona in
                    Button {
                        personaManager.switchPersona(to: persona)
                    } label: {
                        HStack(spacing: Spacing.small) {
                            Image(systemName: persona.icon)
                                .font(.title3)
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
                                    .font(.body)
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

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(storeManager.currentTier.displayName)
                        .foregroundColor(storeManager.isPremium ? .green : AppColors.secondary)
                        .fontWeight(.semibold)
                }

                if storeManager.currentTier < .professional {
                    Button(storeManager.currentTier == .free ? "Upgrade" : "Upgrade to Professional") {
                        storeManager.showPaywall = true
                    }
                }

                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
            } header: {
                Text("Purchase")
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
                        Label(storeManager.currentTier.displayName, systemImage: "crown.fill")
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                    } else {
                        Text("Free")
                            .foregroundColor(.secondary)
                    }
                }

                if storeManager.currentTier < .professional {
                    Button(storeManager.currentTier == .free ? "Upgrade" : "Upgrade to Professional") {
                        storeManager.showPaywall = true
                    }
                }

                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
                .accessibilityLabel("Restore purchases")
            } header: {
                Text("Purchase")
                    .font(.headline)
            } footer: {
                Text("Buy once, own forever. No subscriptions required.")
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
                Picker("Auto-delete data after", selection: $compliance.dataRetentionDays) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                }

                Button("Delete All My Data", role: .destructive) {
                    showDeleteAllConfirmation = true
                }
                .alert("Delete All Data", isPresented: $showDeleteAllConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete Everything", role: .destructive) {
                        compliance.deleteAllUserData()
                        allDataDeleted = true
                    }
                } message: {
                    Text("This will permanently delete ALL data including emails, settings, forensic data, AI keys, and preferences. The app will reset to its initial state. This cannot be undone.")
                }

                if allDataDeleted {
                    Text("All data has been deleted. Restart the app for a clean state.")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                if !compliance.termsAcceptedDateString.isEmpty {
                    HStack {
                        Text("Terms accepted")
                        Spacer()
                        Text(compliance.acceptedTermsVersion)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
            } header: {
                Label("Data & Privacy", systemImage: "hand.raised.fill")
                    .font(.headline)
            } footer: {
                Text("mailin collects zero data. All processing is on-device. Use \"Delete All My Data\" to exercise your right to data deletion (GDPR Art. 17 / CCPA).")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

                HStack(spacing: Spacing.medium) {
                    if let privacyURL = URL(string: "https://sasmalgiri.github.io/mailin/privacy") {
                        Link("Privacy Policy", destination: privacyURL)
                            .font(Typography.caption1)
                    }
                    if let termsURL = URL(string: "https://sasmalgiri.github.io/mailin/terms") {
                        Link("Terms of Use", destination: termsURL)
                            .font(Typography.caption1)
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

    // MARK: - Help & Tips Settings
    @State private var showWhatsNewFromSettings = false
    @State private var tipsReset = false

    private var helpAndTipsSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    helpCard(icon: "1.circle.fill", title: "Import an Archive", description: "Use File > Open (⌘O) or drag-and-drop an .mbox, .eml, .msg, or .pst file into the window.", color: .blue)
                    helpCard(icon: "2.circle.fill", title: "Browse & Filter", description: "Use the filter bar to narrow results by tag, date, sender, or attachment type. Toggle AI and Pro for more filters.", color: .purple)
                    helpCard(icon: "3.circle.fill", title: "Analyze & Export", description: "Click any email to view details. Use the Analysis and Export menus for advanced tools.", color: .green)
                }
            } header: {
                Label("Quick Start", systemImage: "play.circle")
                    .font(.headline)
            }

            Section {
                helpRow(icon: "brain", title: "AI Button", description: "Enables AI-powered tags: sentiment, priority, phishing detection, and email classification.", color: .purple)
                helpRow(icon: "gearshape", title: "Pro Button", description: "Shows forensic, legal, and evidence features: Bates numbering, legal hold, chain of custody.", color: .orange)
                helpRow(icon: "tag", title: "Tag Pills", description: "Click any tag on an email to see all applicable tags. Set manual tags to override AI suggestions.", color: .teal)
                helpRow(icon: "line.3.horizontal.decrease.circle", title: "Filter Chips", description: "Add filter chips from the + menu. Active chips narrow the visible email list. Click × to remove.", color: .blue)
                helpRow(icon: "magnifyingglass", title: "Search Syntax", description: "Use AND, OR, NOT for boolean search. Wrap regex in /slashes/. Use \"word1\" NEAR/5 \"word2\" for proximity.", color: .green)
            } header: {
                Label("Feature Guide", systemImage: "lightbulb")
                    .font(.headline)
            }

            Section {
                HStack {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                    Spacer()
                    Text("⌘⇧/")
                        .font(Typography.monoSmall)
                        .foregroundColor(AppColors.secondary)
                }
                .help("Press ⌘⇧/ to see all keyboard shortcuts")

                HStack {
                    Label("Command Palette", systemImage: "terminal")
                    Spacer()
                    Text("⌘⇧P")
                        .font(Typography.monoSmall)
                        .foregroundColor(AppColors.secondary)
                }
                .help("Press ⌘⇧P to open the command palette for quick access to all features")

                HStack {
                    Label("Guided Search", systemImage: "text.magnifyingglass")
                    Spacer()
                    Text("Help > Search Help")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            } header: {
                Label("Shortcuts", systemImage: "bolt")
                    .font(.headline)
            }

            Section {
                Button("Show What's New") {
                    showWhatsNewFromSettings = true
                }

                Button("Reset All Tips") {
                    try? Tips.resetDatastore()
                    tipsReset = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tipsReset = false }
                }

                if tipsReset {
                    Label("Tips reset — they will appear again as you use the app.", systemImage: "checkmark.circle")
                        .font(Typography.caption1)
                        .foregroundColor(.green)
                }
            } header: {
                Label("Tips & Updates", systemImage: "sparkles")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showWhatsNewFromSettings) {
            WhatsNewView()
        }
    }

    private func helpCard(icon: String, title: String, description: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                Text(description)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func helpRow(icon: String, title: String, description: String, color: Color) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.callout)
                    .fontWeight(.medium)
                Text(description)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Forensic Settings
    private var forensicSettings: some View {
        Form {
            Section {
                Toggle("Enable Forensic Mode", isOn: Binding(
                    get: { forensicManager.isEnabled },
                    set: { newValue in
                        if newValue {
                            if storeManager.requireProfessional() {
                                forensicManager.isEnabled = true
                            }
                        } else {
                            forensicManager.isEnabled = false
                        }
                    }
                ))
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
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text("Forensic mode enables hash verification of source files, a full audit log, evidence tagging, and blocks cloud AI to maintain chain of custody.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Disclaimer: Forensic features are analytical tools and have NOT been independently validated for court admissibility. Verify all outputs independently before use in legal proceedings.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
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
                            .help(Text(verbatim: detail))
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

    // MARK: - Collaboration Settings

    private var collaborationSettings: some View {
        Form {
            Section {
                if !storeManager.isProfessional {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Professional Feature")
                                .font(Typography.headline)
                            Text("Review sharing requires the Professional tier.")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                        Spacer()
                        Button("Upgrade") {
                            storeManager.showPaywall = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, Spacing.xxSmall)
                } else {
                    Toggle("Enable Review Sharing", isOn: $collabManager.isEnabled)
                        .help("Share review state with other reviewers via a shared folder (iCloud Drive, Dropbox, etc.)")
                        .onChange(of: collabManager.isEnabled) { _, enabled in
                            if enabled {
                                collabManager.startMonitoring()
                                collabManager.scanForReviewFiles()
                            } else {
                                collabManager.stopMonitoring()
                            }
                        }

                    if collabManager.isEnabled {
                        HStack {
                            Text("Your reviewer ID")
                            Spacer()
                            TextField("Reviewer ID", text: $collabManager.examinerID)
                                .frame(maxWidth: 200)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Identifies your review state files. Other reviewers will see this name.")
                    }
                }
            } header: {
                Text("Review State Sharing")
                    .font(.headline)
            } footer: {
                Text("Share review progress (tags, annotations, custodians, legal holds) with other reviewers through a shared folder. Email content stays on each device — only review metadata is shared.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if collabManager.isEnabled {
                Section {
                    if let folder = collabManager.sharedFolderURL {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(folder.lastPathComponent)
                                    .font(Typography.callout)
                                Text(folder.path)
                                    .font(Typography.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Change") {
                                chooseSharedFolder()
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button {
                            chooseSharedFolder()
                        } label: {
                            Label("Choose Shared Folder", systemImage: "folder.badge.plus")
                        }
                        .help("Select a folder in iCloud Drive, Dropbox, or any shared location")
                    }

                    Toggle("Auto-export on changes", isOn: $collabManager.autoExport)
                        .help("Automatically save review state to the shared folder when you tag or annotate emails")
                } header: {
                    Text("Shared Folder")
                        .font(.headline)
                } footer: {
                    Text("Point this to a folder in iCloud Drive, Dropbox, Google Drive, or any shared location. mailin will watch for review state files from other reviewers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    if collabManager.availableImports.isEmpty {
                        Text("No review state files from other reviewers found.")
                            .font(Typography.caption1)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(collabManager.availableImports) { file in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Spacing.xxSmall) {
                                        if file.isNew {
                                            Circle()
                                                .fill(.blue)
                                                .frame(width: 8, height: 8)
                                        }
                                        Text(file.examiner)
                                            .font(Typography.callout)
                                            .fontWeight(file.isNew ? .semibold : .regular)
                                    }
                                    Text("\(file.age) \(file.caseNumber.isEmpty ? "" : "- Case: \(file.caseNumber)")")
                                        .font(Typography.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Import") {
                                    importCollabFile(file)
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    Button {
                        collabManager.scanForReviewFiles()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                } header: {
                    HStack {
                        Text("Available from Others")
                            .font(.headline)
                        if collabManager.newImportCount > 0 {
                            Text("\(collabManager.newImportCount) new")
                                .font(Typography.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, Spacing.xxSmall)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .cornerRadius(CornerRadius.round)
                        }
                    }
                }

                if !collabManager.statusMessage.isEmpty {
                    Section {
                        Text(collabManager.statusMessage)
                            .font(Typography.caption1)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(iOS)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                collabManager.setSharedFolder(url)
            }
        }
        #endif
    }

    // MARK: - iCloud Sync Settings

    private var iCloudSyncSettings: some View {
        Form {
            Section {
                if !storeManager.isProfessional {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Professional Feature")
                                .font(Typography.headline)
                            Text("iCloud Sync requires the Professional tier.")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }
                        Spacer()
                        Button("Upgrade") {
                            storeManager.showPaywall = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, Spacing.xxSmall)
                } else {
                    Toggle("Enable iCloud Sync", isOn: $iCloudSync.isEnabled)
                        .help("Sync forensic metadata (evidence tags, annotations, case info) across your devices via iCloud")

                    if iCloudSync.isEnabled {
                        HStack {
                            Image(systemName: iCloudSync.syncStatus.icon)
                                .foregroundColor(iCloudSync.syncStatus.color)
                            Text(iCloudSync.syncStatus.label)
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                            Spacer()
                            if let lastSync = iCloudSync.lastSyncDate {
                                Text(lastSync.formatted(date: .omitted, time: .shortened))
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                            }
                        }

                        if !iCloudSync.isAvailable {
                            HStack(spacing: Spacing.xSmall) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Sign in to iCloud in System Settings to enable sync.")
                                    .font(Typography.caption1)
                                    .foregroundColor(.orange)
                            }
                        }

                        Button("Sync Now") {
                            iCloudSync.forceSyncNow()
                        }
                        .disabled(!iCloudSync.isAvailable)
                    }
                }
            } header: {
                Text("iCloud Sync")
                    .font(.headline)
            } footer: {
                Text("Syncs evidence tags, annotations, and case information across your devices. Email content is never uploaded — only forensic metadata is synced.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if storeManager.isProfessional && iCloudSync.isEnabled {
                Section {
                    HStack {
                        Text("Synced Data")
                        Spacer()
                        Text("Evidence tags, annotations, case info")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                    HStack {
                        Text("Sync Interval")
                        Spacer()
                        Text("Every 60 seconds")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                    HStack {
                        Text("Email Content")
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Never uploaded")
                                .font(Typography.caption1)
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("Sync Details")
                        .font(.headline)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseSharedFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a shared folder (iCloud Drive, Dropbox, etc.) for collaboration"
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        collabManager.setSharedFolder(url)
        #else
        showFolderPicker = true
        #endif
    }

    private func importCollabFile(_ file: CollaborationManager.ReviewStateFile) {
        do {
            let result = try collabManager.importFile(file)
            collabManager.statusMessage = result.total > 0
                ? "Imported from \(file.examiner): \(result.summary)"
                : "Already up to date with \(file.examiner)'s review state."
        } catch {
            collabManager.statusMessage = "Import failed: \(error.localizedDescription)"
        }
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
        autoAdvanceAfterTag = true
        hasConsentedToCloudAI = false
        KeychainHelper.delete(key: "apiKey")
        customModelName = ""
    }
}

#Preview {
    SettingsView()
        .environmentObject(StoreManager())
}
