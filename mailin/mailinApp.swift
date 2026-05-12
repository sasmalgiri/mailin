//
//  mailinApp.swift
//  mailin
//
//  Created by administrator on 12/07/2025.
//
//  A professional email archive analyzer for Apple platforms.
//  Parses .mbox and .eml files with advanced filtering and AI insights.
//

import SwiftUI
import Observation
import CoreSpotlight
import TipKit
#if os(macOS)
import AppKit
#endif

@main
struct mailinApp: App {
    // MARK: - App State
    @State private var appState = AppStateManager()
    @StateObject private var storeManager = StoreManager()
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @ObservedObject private var compliance = LegalComplianceManager.shared
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @AppStorage("hasSeenLaunchAnimation") private var hasSeenLaunchAnimation = false
    @State private var showLaunchAnimation = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Scene Configuration
    var body: some Scene {
        // Main window with proper sizing and controls
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(appState)
                    .environmentObject(storeManager)
                    .adaptiveLayout()
                    #if os(macOS)
                    .frame(minWidth: 700, idealWidth: 1100, minHeight: 500, idealHeight: 750)
                    #endif
                    .sheet(isPresented: Binding(
                        get: { compliance.needsTermsAcceptance },
                        set: { _ in }
                    )) {
                        TermsAcceptanceView()
                            .interactiveDismissDisabled()
                    }
                    .sheet(isPresented: Binding(
                        get: { !compliance.needsTermsAcceptance && !personaManager.hasCompletedPersonaSelection },
                        set: { if !$0 { personaManager.completePersonaSelection() } }
                    )) {
                        PersonaOnboardingView()
                            .interactiveDismissDisabled()
                    }
                    .onAppear {
                        configureAppearance()
                        ImportProgressNotifier.shared.requestPermission()
                        try? Tips.configure([
                            .displayFrequency(.weekly)
                        ])
                        if !hasSeenLaunchAnimation {
                            showLaunchAnimation = true
                        }
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .active {
                            Task { await storeManager.checkEntitlements() }
                        }
                        #if os(iOS)
                        if newPhase == .background {
                            EmailPersistence.flushPendingSaves()
                        }
                        #endif
                    }
                    .onOpenURL { url in
                        handleIncomingURL(url)
                    }
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        if let emailID = SpotlightIndexer.shared.handleSpotlightActivity(activity) {
                            NotificationCenter.default.post(name: .spotlightEmailSelected, object: emailID)
                        }
                    }

                if showLaunchAnimation {
                    LaunchAnimationView {
                        showLaunchAnimation = false
                        hasSeenLaunchAnimation = true
                    }
                    .zIndex(999)
                }
            }
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
        .commands {
            appCommands
        }

        #if os(macOS)
        // Settings window (Apple standard)
        Settings {
            SettingsView()
                .environment(appState)
                .environmentObject(storeManager)
        }

        // About window
        Window("About mailin", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 500)
        #endif
    }
    
    // MARK: - Menu Commands (Apple Standard)
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About mailin") {
                #if os(macOS)
                openWindow(id: "about")
                #endif
            }
        }
        
        CommandGroup(replacing: .newItem) {
            Button("New Import") {
                appState.triggerNewImport = true
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open Email Archive...") {
                appState.triggerFileImport = true
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Export Filtered Emails (Pro)...") {
                if storeManager.requirePremium() {
                    appState.triggerExport = true
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!appState.hasFilteredEmails)

            Divider()

            Button("Export Contacts (vCard)...") {
                appState.triggerExportVCard = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Export Calendar Events (ICS)...") {
                appState.triggerExportICS = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Export Headers Only (CSV)...") {
                appState.triggerExportHeadersCSV = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Batch Print All Filtered...") {
                appState.triggerBatchPrint = true
            }
            .disabled(!appState.hasFilteredEmails)
        }
        
        CommandGroup(replacing: .textEditing) {
            Button("Find...") {
                appState.triggerSearch = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!appState.hasParsedEmails)

            Button("Select All") {
                appState.triggerSelectAll = true
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!appState.hasParsedEmails)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print Email...") {
                appState.triggerPrint = true
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!appState.hasParsedEmails)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                appState.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            Button("Command Palette...") {
                appState.showCommandPalette = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Keyboard Shortcuts...") {
                appState.showKeyboardShortcuts = true
            }

            Divider()

            Button("Workspaces...") {
                appState.showWorkspaceManager = true
            }
        }

        CommandMenu("Analysis") {
            Button("Reply Statistics...") {
                appState.showReplyStats = true
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Button("Ask AI...") {
                appState.showAIAssistant = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!appState.hasParsedEmails || !enableAIFeatures)

            Button("Visual Analytics...") {
                appState.showAnalytics = true
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Detect Metadata") {
                appState.detectMetadata()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Topic Clusters") {
                withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics }
            }
            .disabled(!appState.hasParsedEmails)

            Button("Email Subjects") {
                withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .subjects ? nil : .subjects }
            }
            .disabled(!appState.hasParsedEmails)

            Button("Find Duplicates...") {
                appState.showDuplicateManager = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Predictive Coding (TAR)...") {
                appState.showPredictiveCoding = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Attachment Browser...") {
                appState.showAttachmentGrid = true
            }
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Email Timeline...") {
                appState.showTimeline = true
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Button("Relationship Graph...") {
                appState.showRelationshipGraph = true
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Archive Comparison...") {
                appState.showArchiveComparison = true
            }
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Automation Rules...") {
                appState.showAutomationRules = true
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!appState.hasParsedEmails)

            Button("Batch Operations...") {
                appState.showBatchOperations = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("All Attachments...") {
                appState.showAllAttachmentsGallery = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("IOC Extractor...") {
                appState.showIOCExtractor = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Guided Search...") {
                appState.showGuidedSearch = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Thread Summary...") {
                appState.showThreadSummarizer = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Smart Alerts...") {
                appState.showSmartAlerts = true
            }
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Near-Duplicate Detection...") {
                appState.showNearDuplicates = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Anomaly Detection...") {
                appState.showAnomalyDetection = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Smart Auto-Tagger...") {
                appState.showSmartAutoTagger = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Email Digest...") {
                appState.showAIDigest = true
            }
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("Executive Dashboard...") {
                appState.showExecutiveDashboard = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Communication Patterns...") {
                appState.showCommunicationPatterns = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Keyword Monitor...") {
                appState.showKeywordMonitor = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Report Builder...") {
                appState.showReportBuilder = true
            }
            .disabled(!appState.hasParsedEmails)
        }

        CommandMenu("Export") {
            Button("Export as MSG...") {
                appState.triggerExportMSG = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Export as PST...") {
                appState.triggerExportPST = true
            }
            .disabled(!appState.hasParsedEmails)

            Button("Export Relativity Load File...") {
                appState.triggerExportRelativity = true
            }
            .disabled(!appState.hasParsedEmails)
        }

        CommandMenu("Forensic") {
            Toggle("Forensic Mode", isOn: $forensicManager.isEnabled)
                .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button("Export Audit Log...") {
                appState.triggerAuditLogExport = true
            }
            .disabled(!forensicManager.isEnabled || forensicManager.auditLog.isEmpty)

            Button("Export Forensic CSV...") {
                appState.triggerForensicCSVExport = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("Export Hash Manifest...") {
                appState.triggerExportHashManifest = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("Verify All Email Integrity") {
                appState.triggerVerifyIntegrity = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Divider()

            Button("Custodian Manager...") {
                appState.showCustodianPanel = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("Review Batches...") {
                appState.showReviewBatches = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("Generate Investigation Report...") {
                appState.showInvestigationReport = true
            }
            .disabled(!appState.hasParsedEmails)

            Divider()

            Button("E-Discovery Workflow...") {
                appState.showEDiscovery = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("Bates Numbering...") {
                appState.showBatesNumbering = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("PII Redaction...") {
                appState.showRedaction = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("GDPR Compliance Report...") {
                appState.showGDPRReport = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Button("Chain of Custody...") {
                appState.showChainOfCustody = true
            }
            .disabled(!forensicManager.isEnabled || !appState.hasParsedEmails)

            Divider()

            Section("Evidence Tags") {
                Button("Tag: Relevant") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.relevant)
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Privileged") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.privileged)
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Irrelevant") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.irrelevant)
                }
                .keyboardShortcut("3", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Flagged") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.flagged)
                }
                .keyboardShortcut("4", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)

                Button("Tag: Suspicious") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.suspicious)
                }
                .keyboardShortcut("5", modifiers: [.command, .shift])
                .disabled(!appState.hasParsedEmails)

                Button("Clear Tag") {
                    NotificationCenter.default.post(name: .tagCurrentEmail, object: ForensicManager.EvidenceTag.none)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(!appState.hasParsedEmails)
            }
        }

        CommandGroup(replacing: .help) {
            Button("What's New...") {
                appState.showWhatsNew = true
            }

            Button("Keyboard Shortcuts") {
                appState.showKeyboardShortcuts = true
            }
            .keyboardShortcut("?", modifiers: [.command])

            Button("Search Help...") {
                appState.showGuidedSearch = true
            }

            Divider()

            if let supportURL = URL(string: "https://sasmalgiri.github.io/mailin/support") {
                Link("mailin Support", destination: supportURL)
            }
            if let privacyURL = URL(string: "https://sasmalgiri.github.io/mailin/privacy") {
                Link("Privacy Policy", destination: privacyURL)
            }
        }
    }
    
    private static var terminationObserverRegistered = false

    private func handleIncomingURL(_ url: URL) {
        let scheme = url.scheme ?? ""
        if scheme == "com.ecosanskriti.mailin" || scheme == "msauth.com.ecosanskriti.mailin" {
            NotificationCenter.default.post(name: .oauthCallback, object: url)
        } else {
            let ext = url.pathExtension.lowercased()
            if ParserFactory.allSupportedExtensions.contains(ext) {
                NotificationCenter.default.post(name: .importFileFromURL, object: url)
            }
        }
    }

    // MARK: - Appearance Configuration
    private func configureAppearance() {
        #if os(macOS)
        if !Self.terminationObserverRegistered {
            Self.terminationObserverRegistered = true
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                EmailPersistence.flushPendingSaves()
            }
        }
        #endif
    }
}
// MARK: - App State Manager
@Observable
@MainActor
class AppStateManager {
    var triggerFileImport = false
    var triggerExport = false
    var showReplyStats = false
    var showAIAssistant = false
    var showAnalytics = false
    var showReplyStatsSheet = false
    var hasFilteredEmails = false
    var hasParsedEmails = false
    var sidebarVisible = true
    var triggerAuditLogExport = false
    var triggerForensicCSVExport = false
    var triggerSearch = false
    var triggerSelectAll = false
    var triggerPrint = false
    var triggerNewImport = false
    var showDuplicateManager = false
    var showTopicClusters = false
    var showPredictiveCoding = false
    var showCustodianPanel = false
    var showReviewBatches = false
    var triggerExportVCard = false
    var triggerExportICS = false
    var triggerExportHashManifest = false
    var triggerExportHeadersCSV = false
    var triggerBatchPrint = false
    var triggerVerifyIntegrity = false
    var showAttachmentGrid = false
    var triggerExportMSG = false
    var triggerExportPST = false
    var triggerExportRelativity = false
    var showTimeline = false
    var showRelationshipGraph = false
    var showArchiveComparison = false
    var showInvestigationReport = false
    var showAuditTrail = false
    // v7: Intelligence & Automation
    var showAutomationRules = false
    var showBatchOperations = false
    var showThreadSummarizer = false
    var showSmartAlerts = false
    // v7: Forensics & Compliance
    var showEDiscovery = false
    var showBatesNumbering = false
    var showRedaction = false
    var showGDPRReport = false
    var showChainOfCustody = false
    // v8: Intelligence & Polish
    var showNearDuplicates = false
    var showAnomalyDetection = false
    var showSmartAutoTagger = false
    var showAIDigest = false
    // v9: Dashboard & Reporting
    var showExecutiveDashboard = false
    var showReportBuilder = false
    var showKeywordMonitor = false
    var showCommunicationPatterns = false
    // v9: Security & Workspaces
    var showWorkspaceManager = false
    var showCommandPalette = false
    var showKeyboardShortcuts = false
    var showWhatsNew = false
    // v10: User-requested features
    var showAllAttachmentsGallery = false
    var showIOCExtractor = false
    var showGuidedSearch = false
    var showExportProgress = false
    var exportProgressValue: Double = 0
    var exportProgressMessage: String = ""
    var dockedBottomPanel: DockedPanel? = nil

    enum DockedPanel: String {
        case topics, subjects
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func detectMetadata() {
        NotificationCenter.default.post(name: .detectMetadata, object: nil)
    }
}

// MARK: - Persona Onboarding

struct PersonaOnboardingView: View {
    @ObservedObject private var personaManager = PersonaManager.shared
    @State private var selected: PersonaManager.Persona = .general
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.small) {
                Image(systemName: "envelope.open.badge.clock")
                    .font(.largeTitle)
                    .foregroundStyle(.linearGradient(
                        colors: [selected.accentColor, selected.accentColor.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))

                Text("Welcome to mailin")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)

                Text("How will you use mailin? This sets your default layout, visible tools, and AI suggestions. You can change it anytime in Settings.")
                    .font(Typography.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Spacing.large)
            .padding(.bottom, Spacing.medium)

            ScrollView {
                VStack(spacing: Spacing.xSmall) {
                    ForEach(PersonaManager.Persona.allCases, id: \.rawValue) { persona in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selected = persona }
                        } label: {
                            HStack(spacing: Spacing.small) {
                                Image(systemName: persona.icon)
                                    .font(.title3)
                                    .foregroundColor(persona.accentColor)
                                    .frame(width: 32, height: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.displayName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    Text(persona.tagline)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                    if selected == persona {
                                        Text(persona.impactDescription)
                                            .font(.caption2)
                                            .foregroundColor(persona.accentColor.opacity(0.8))
                                            .lineLimit(2)
                                            .transition(.opacity)
                                    }
                                }

                                Spacer()

                                if selected == persona {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(persona.accentColor)
                                        .font(.headline)
                                }
                            }
                            .padding(Spacing.small)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.medium)
                                    .fill(selected == persona
                                          ? persona.accentColor.opacity(0.08)
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.medium)
                                    .stroke(selected == persona
                                            ? persona.accentColor.opacity(0.4)
                                            : Color.gray.opacity(0.15), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.medium)
            }

            Divider()
                .padding(.top, Spacing.small)

            HStack {
                Button("Skip") {
                    personaManager.completePersonaSelection()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Skip persona selection")

                Spacer()

                Text("You can change this anytime in Settings.")
                    .font(Typography.caption1)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Get Started") {
                    personaManager.switchPersona(to: selected)
                    personaManager.completePersonaSelection()
                    dismiss()
                }
                .buttonStyle(CompactPrimaryButtonStyle())
                .tint(selected.accentColor)
            }
            .padding(Spacing.medium)
        }
        .adaptiveHeroBackground(colors: [selected.accentColor, .purple, .indigo, .teal])
        #if os(macOS)
        .frame(width: 460, height: 480)
        #endif
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let detectMetadata = Notification.Name("detectMetadata")
    static let dataClearedByUser = Notification.Name("dataClearedByUser")
    static let tagCurrentEmail = Notification.Name("tagCurrentEmail")
    static let printCurrentEmail = Notification.Name("printCurrentEmail")
    static let oauthCallback = Notification.Name("oauthCallback")
    static let importFileFromURL = Notification.Name("importFileFromURL")
    static let triggerFileImportFromShortcut = Notification.Name("triggerFileImportFromShortcut")
    static let spotlightEmailSelected = Notification.Name("spotlightEmailSelected")
    static let togglePinEmail = Notification.Name("togglePinEmail")
    static let addTagToEmail = Notification.Name("addTagToEmail")
}

