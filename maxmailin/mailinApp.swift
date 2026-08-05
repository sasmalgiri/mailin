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

#if os(macOS)
class MailinAppDelegate: NSObject, NSApplicationDelegate {
    @objc func printDocument(_ sender: Any?) {
        NotificationCenter.default.post(name: .printCurrentEmail, object: nil)
    }
}
#endif

/// One-of-N enum for the launch-time gating sheets. Used with
/// `.sheet(item:)` so SwiftUI presents exactly one at a time, in priority
/// order (terms first, then persona onboarding).
private enum LaunchSheet: String, Identifiable {
    case terms, persona
    var id: String { rawValue }
}

@main
struct mailinApp: App {
    // MARK: - App State
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MailinAppDelegate.self) var appDelegate
    #endif
    @State private var appState = AppStateManager()
    @StateObject private var storeManager = StoreManager()
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @ObservedObject private var compliance = LegalComplianceManager.shared
    @ObservedObject private var biometricLock = BiometricLockManager.shared
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
                    .frame(minWidth: 520, idealWidth: 1100, minHeight: 400, idealHeight: 750)
                    #endif
                    // Single sheet attachment for the launch gating flow.
                    // Stacking two separate .sheet modifiers on the same view
                    // causes SwiftUI to log "Currently, only presenting a
                    // single sheet is supported" faults when both bindings
                    // briefly evaluate true during launch — even if one is
                    // guarded against the other. Using .sheet(item:) with an
                    // enum produces exactly one presentation at a time.
                    .sheet(item: Binding<LaunchSheet?>(
                        get: {
                            if compliance.needsTermsAcceptance { return .terms }
                            if !personaManager.hasCompletedPersonaSelection { return .persona }
                            return nil
                        },
                        set: { newValue in
                            // Dismissing the persona sheet completes selection.
                            // Terms acceptance is dismissed only by accepting
                            // inside the sheet (interactiveDismissDisabled), so
                            // we never observe a nil set for .terms.
                            if newValue == nil && !personaManager.hasCompletedPersonaSelection {
                                personaManager.completePersonaSelection()
                            }
                        }
                    )) { sheet in
                        switch sheet {
                        case .terms:
                            TermsAcceptanceView()
                                .interactiveDismissDisabled()
                        case .persona:
                            PersonaOnboardingView()
                                .interactiveDismissDisabled()
                        }
                    }
                    .onAppear {
                        StoreManager.resetDailyCountersIfNeeded()
                        configureAppearance()
                        // Notification permission is opt-in via Settings → General
                        // → Notifications, not auto-prompted at launch.
                        BackgroundAnalysisManager.shared.scheduleBackgroundAnalysis()
                        try? Tips.configure([
                            .displayFrequency(.weekly)
                        ])
                        if !hasSeenLaunchAnimation {
                            showLaunchAnimation = true
                        }
                    }
                    .task {
                        // Privacy / robustness wiring.
                        MemoryPressureHandler.shared.start()
                        // Under memory pressure, ask FTS5 to close all but
                        // the two most-recently-used shard handles. The
                        // shards re-open lazily on next access — no data
                        // loss, just dropped SQLite page caches (typically
                        // tens of MB per shard).
                        MemoryPressureHandler.shared.register { level in
                            let keep = level == .warning ? 4 : 2
                            Task { await FTSSearchIndex.shared.evictIdleShards(keep: keep) }
                        }
                        // Drop FoundationModels caches under pressure.
                        // The answer cache and conversation memory are
                        // optional speedups — losing them costs us a
                        // re-prompt, not a feature. On critical pressure,
                        // also drop the profile cache and precomputation
                        // state.
                        MemoryPressureHandler.shared.register { level in
                            #if canImport(FoundationModels)
                            if #available(macOS 26, iOS 26, *) {
                                FoundationModelEngine.invalidateAnswerCache()
                                if level != .warning {
                                    FoundationModelEngine.invalidateProfileCache()
                                    FoundationModelEngine.invalidatePrecomputation()
                                    FoundationModelEngine.clearConversationMemory()
                                }
                            }
                            #endif
                        }
                        // Drop NLP / AIAssistantView caches under pressure.
                        // These hold tokenised text and pre-computed
                        // analysis that can be rebuilt on demand.
                        MemoryPressureHandler.shared.register { level in
                            Task { @MainActor in
                                AIAssistantView.invalidateNLPCache()
                                if level != .warning {
                                    AIAssistantView.invalidateNLPPrecomputation()
                                }
                            }
                        }
                        // CRITICAL pressure only: drop the in-RAM
                        // EmailSearchIndex. At a 100K-message archive this
                        // dictionary set is typically 200–400 MB resident
                        // — the single biggest reclaimable allocation.
                        // The disk-persisted index files are untouched;
                        // the next search rebuilds RAM state from them.
                        MemoryPressureHandler.shared.register { level in
                            guard level != .warning else { return }
                            EmailSearchIndex.shared.dropInMemoryIndices()
                        }
                        await AppSelfAttestation.shared.compute()

                        // maxmailin v2 SwiftData layer: migrate any legacy JSON
                        // archive from earlier mailin installs into the new
                        // SwiftData store. Idempotent — only runs once per
                        // archive version, immediately returns on subsequent
                        // launches.
                        await MigrationService.shared.migrateIfNeeded()

                        // Stage 5A: establish SQLite as the production storage
                        // authority BEFORE any archive read/write. On an
                        // existing SwiftData install this migrates it (non-
                        // destructively) into SQLite and only marks `.active`
                        // after the count + reopen integrity gate passes. Import
                        // and the read cutover gate on `isActive`. Idempotent —
                        // a fast no-op once active.
                        let storageState = await StorageActivationCoordinator.shared.activate()
                        _ = try? HMACChainAuditLog.shared.append(
                            action: "v2.storage.activation",
                            detail: "SQLite activation state: \(storageState.rawValue)"
                        )

                        // Repair any store↔FTS drift (a crash between the
                        // store commit and the FTS commit can leave a row in
                        // the store but unsearchable). Only runs when drift is
                        // detected; bounded so it can't load an unbounded
                        // archive into memory.
                        Task.detached(priority: .utility) {
                            // Reconcile against the ACTIVE authority. Once SQLite
                            // is active (Stage 5A), it is the canonical store the
                            // FTS index must match; before activation, fall back
                            // to the SwiftData store.
                            let active = await StorageActivationCoordinator.shared.isActive
                            let store: any EmailArchiveStore = active ? SQLiteEmailStore.shared : EmailStore.shared
                            let storeCount = (try? await store.totalCount()) ?? 0
                            let ftsCount = (try? await FTSSearchIndex.shared.rowCount()) ?? 0
                            if storeCount > ftsCount {
                                // Bounded, paged, restartable — no archive-wide
                                // Set<UUID>, no 100k ceiling. Best-effort at
                                // launch; a failure just retries next launch.
                                _ = try? await FTSReconciler.reconcile(store: store, fts: .shared)
                            }
                        }

                        // Self-test exercises the v2 storage + search +
                        // import pipeline against the bundled sample once
                        // per install. Logs via os.log "SelfTest".
                        // Debug-only: skipped in App Store / TestFlight builds.
                        #if DEBUG
                        let selfTestResult = await MaxmailinSelfTest.shared.runIfNeeded()
                        #else
                        let selfTestResult: MaxmailinSelfTest.Result = .skipped
                        #endif

                        // Tamper-evident HMAC chain genesis entry on first
                        // launch; subsequent launches append a "launch" event
                        // so the chain shows continuous operation.
                        switch selfTestResult {
                        case .passed:
                            _ = try? HMACChainAuditLog.shared.append(
                                action: "v2.selfTest.passed",
                                detail: "Maxmailin v2 self-test passed"
                            )
                        case .failed(let msg):
                            _ = try? HMACChainAuditLog.shared.append(
                                action: "v2.selfTest.failed",
                                detail: msg
                            )
                        case .skipped:
                            _ = try? HMACChainAuditLog.shared.append(
                                action: "v2.launch",
                                detail: "maxmailin launched"
                            )
                        }
                        _ = HMACChainAuditLog.shared.verifyChain()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        biometricLock.handleScenePhaseChange(newPhase)
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

                // Biometric lock gate. Topmost overlay so the archive is never
                // visible until the user authenticates (Touch ID / Face ID /
                // passcode). Driven by the "biometricLockEnabled" setting; the
                // manager starts locked at launch when the setting is on.
                if biometricLock.isLocked {
                    BiometricLockView(manager: biometricLock)
                        .zIndex(1000)
                        .transition(.opacity)
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

        // Mail menu (Compose / Connect / Fetch) removed in v2 — mailin is
        // strictly offline by design.

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
        // OAuth callback schemes were removed in v2 — mailin is strictly
        // offline. The only incoming URLs we honour are file imports.
        let ext = url.pathExtension.lowercased()
        if ParserFactory.allSupportedExtensions.contains(ext) {
            NotificationCenter.default.post(name: .importFileFromURL, object: url)
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
    // (Send/Receive & Cloud-Connect flags removed in v2 — mailin is
    // strictly offline.)

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
                    ForEach(PersonaManager.Persona.pickableCases, id: \.rawValue) { persona in
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
        .frame(minWidth: 360, idealWidth: 460, minHeight: 380, idealHeight: 480)
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
    static let composeEmailSent = Notification.Name("composeEmailSent")
    static let deleteCurrentEmail = Notification.Name("deleteCurrentEmail")
    static let archiveCurrentEmail = Notification.Name("archiveCurrentEmail")
    static let toggleReadCurrentEmail = Notification.Name("toggleReadCurrentEmail")
}

