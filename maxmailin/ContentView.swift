import SwiftUI
import UniformTypeIdentifiers
import StoreKit
import TipKit
#if os(macOS)
import AppKit
#endif

// MARK: - Smart Review Prompt Manager

enum ReviewPromptManager {
    @AppStorage("reviewPrompt_importCount") static var importCount = 0
    @AppStorage("reviewPrompt_lastPromptDate") static var lastReviewPromptDateStr = ""

    static func recordImport() {
        importCount += 1
        checkAndPrompt()
    }

    static func checkAndPrompt() {
        // Only prompt after 3+ successful imports
        guard importCount >= 3 else { return }

        // Don't prompt more than once per 90 days
        let formatter = ISO8601DateFormatter()
        if let lastDate = formatter.date(from: lastReviewPromptDateStr) {
            let daysSince = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
            if daysSince < 90 { return }
        }

        // Request review using platform-appropriate API
        #if os(macOS)
        SKStoreReviewController.requestReview()
        #elseif os(iOS)
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            SKStoreReviewController.requestReview(in: windowScene)
        }
        #endif

        lastReviewPromptDateStr = formatter.string(from: Date())
    }
}

struct ContentView: View {
    @Environment(AppStateManager.self) var appState
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var collabManager = CollaborationManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @Environment(\.windowSizeClass) private var sizeClass
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @AppStorage("autoDetectSender") private var autoDetectSender = true
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false
    @AppStorage("removeDuplicates") private var removeDuplicates = true
    // List mode, user-facing (Settings ▸ Display ▸ List Mode):
    //   true  = Simple   → clean ArchiveListView (default).
    //   false = Advanced → ParsedEmailListView with the full filter/sort/
    //           smart-tag/saved-search toolkit.
    // Part S: PURE presentation preference. Both modes page the same bounded
    // repository-backed architecture (ArchiveDataService); there is no
    // architectural fallback or rollback semantics behind this flag.
    @AppStorage(ListModePreference.key) private var preferSimpleList = ListModePreference.defaultSimple
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var modelVM: ParsedEmailListViewModel
    @State private var showSpinner = false
    @State private var parseFailed = false
    @State private var parsingObserver: NSObjectProtocol?
    @State private var selectedEmailIDs = Set<UUID>()
    /// O1: true while a "Select All" is symbolic — bulk actions then consume
    /// `.query(currentArchiveQuery, exclusions:)` instead of a materialized set.
    @State private var selectAllMatching = false
    @State private var showNewImportConfirmation = false
    @State private var selectedFolder: String?
    @State private var selectedClusterFilter: String?
    @State private var bottomPanelHeight: CGFloat = 250
    @State private var dragStartHeight: CGFloat = 250
    @State private var showRemovedDuplicates = false
    @State private var sidebarSelection: HubDestination?
    @State private var navigationHistory: [HubDestination] = []
    @State private var isNavigatingBack = false

    // Sidebar section expansion state. For the Personal persona we default
    // the advanced groups to collapsed; power personas keep them expanded.
    @State private var showGlossary: Bool = false
    @State private var showGettingStarted: Bool = false
    @State private var showImportErrorAlert: Bool = false
    @State private var importErrorMessage: String = ""

    @State private var browseExpanded: Bool = true
    @State private var analysisExpanded: Bool = !(PersonaManager.shared.selectedPersona == .personal)
    @State private var securityExpanded: Bool = !(PersonaManager.shared.selectedPersona == .personal)
    @State private var legalForensicExpanded: Bool = !(PersonaManager.shared.selectedPersona == .personal)
    @State private var exportReportsExpanded: Bool = !(PersonaManager.shared.selectedPersona == .personal)
    @State private var aiIntelligenceExpanded: Bool = !(PersonaManager.shared.selectedPersona == .personal)
    #if os(iOS)
    @State private var showFileImporter = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showIOSSettings = false
    @State private var showReviewImporter = false
    @State private var showFiltersSheet = false
    @State private var iPadSelectedEmailID: UUID?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @ObservedObject private var predictiveEngine = PredictiveCodingEngine.shared
    @ObservedObject private var custodianManager = CustodianManager.shared
    @ObservedObject private var reviewBatchManager = ReviewBatchManager.shared

    init() {
        // Part S: one-time migration of the stored list-mode preference key.
        ListModePreference.migrateIfNeeded()
        let vm = ContentViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        _modelVM = StateObject(wrappedValue: ParsedEmailListViewModel(viewModel: vm))
    }

    var body: some View {
        @Bindable var appState = appState
        ZStack {
            VStack(spacing: 0) {
                if forensicManager.isEnabled {
                    forensicModeBanner
                }
                mainLayout
            }

            if showSpinner || (viewModel.loadingProgress > 0 && viewModel.loadingProgress < 1) {
                overlaySpinner
            }

            VStack {
                if parseFailed {
                    InfoBanner(
                        text: "Could not parse this file. Supported formats: .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf, .zip",
                        color: AppColors.error, systemImage: "exclamationmark.triangle.fill"
                    ).padding(.top, Spacing.large)
                }
                Spacer()
            }
        }
        .onDrop(of: [.fileURL, .emailMessage], isTargeted: nil) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.emailMessage.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.emailMessage.identifier) { data, _ in
                        guard let data = data else { return }
                        Task { @MainActor in
                            let tempDir = FileManager.default.temporaryDirectory
                            let tempFile = tempDir.appendingPathComponent("dropped_\(UUID().uuidString).eml")
                            do {
                                try data.write(to: tempFile, options: .atomic)
                                resolveAndHandleSelectedFile(tempFile)
                            } catch {
                                viewModel.statusMessage = "Failed to save dropped email: \(error.localizedDescription)"
                                viewModel.statusColor = .red
                            }
                        }
                    }
                    return true
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url = url else { return }
                        let ext = url.pathExtension.lowercased()
                        guard ParserFactory.allSupportedExtensions.contains(ext) || ext == "zip" else { return }
                        Task { @MainActor in
                            if ext == "zip" {
                                let extracted = await viewModel.extractMailFilesFromZipAsync(at: url)
                                if extracted.isEmpty {
                                    parseFailed = true
                                } else {
                                    handleMultipleFiles(extracted)
                                }
                            } else {
                                resolveAndHandleSelectedFile(url)
                            }
                        }
                    }
                    return true
                }
            }
            return false
        }
        .onChange(of: modelVM.isParsed) { handleParseStateChange() }
        .onChange(of: storeManager.isPremium) { handlePremiumChange() }
        .onChange(of: modelVM.visibleEmails.count) { handleFilteredChange() }
        .onAppear { handleAppear() }
        .onChange(of: viewModel.parseErrors) { _, errors in
            // Surface a friendly error sheet when parsing fails. Apple App
            // Review specifically tests corrupt/unsupported inputs.
            guard !errors.isEmpty, !viewModel.isParsed else { return }
            let combined = viewModel.statusMessage.isEmpty
                ? errors.prefix(3).joined(separator: "\n")
                : viewModel.statusMessage
            importErrorMessage = combined + "\n\nTry a different file, or check that the archive isn't corrupt."
            showImportErrorAlert = true
        }
        .onDisappear { handleDisappear() }
        .onReceive(NotificationCenter.default.publisher(for: .dataClearedByUser)) { _ in handleDataCleared() }
        .onReceive(NotificationCenter.default.publisher(for: .detectMetadata)) { _ in viewModel.autoDetectMetadata() }
        .onReceive(NotificationCenter.default.publisher(for: .triggerFileImportFromShortcut)) { _ in openPanelFallback() }
        .onReceive(NotificationCenter.default.publisher(for: .importFileFromURL)) { notification in
            // "Open with mailin" from Finder/Files: mailinApp posts the file
            // URL here. Route it through the same handler as every other
            // entry point (previously this notification had no observer, so
            // opening a file with the app silently did nothing).
            if let url = notification.object as? URL {
                resolveAndHandleSelectedFile(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spotlightEmailSelected)) { notification in
            if let emailID = notification.object as? UUID {
                selectedEmailIDs = [emailID]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePinEmail)) { notification in
            if let emailID = notification.object as? UUID {
                modelVM.togglePin(emailID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addTagToEmail)) { notification in
            if let (emailID, tag) = notification.object as? (UUID, String) {
                modelVM.addUserTag(tag, to: emailID)
            }
        }
        .modifier(EmailManagementModifier(modelVM: modelVM, selectedEmailIDs: $selectedEmailIDs))
        .modifier(MenuTriggerModifier(
            appState: appState,
            onFileImport: { openPanelFallback() },
            onExport: { exportFilteredEmailsAsEML() },
            onAuditLog: { exportAuditLog() },
            onForensicCSV: { exportBulkForensicCSV() },
            onSearch: { handleTriggerSearch() },
            onSelectAll: { handleTriggerSelectAll() },
            onPrint: { handleTriggerPrint() },
            onNewImport: { handleTriggerNewImport() }
        ))
        .sheet(isPresented: $appState.showAIAssistant) {
            AIAssistantView(
                archiveScope: currentAIScope,
                searchContext: modelVM.searchText,
                onSelectEmail: { emailID in
                    selectedEmailIDs = [emailID]
                },
                onFilterByIDs: { ids in
                    modelVM.aiPinnedIDs = Set(ids)
                    modelVM.applyFilters()
                }
            )
            .environmentObject(storeManager)
            #if os(macOS)
            .resizableSheet()
            #else
            .presentationDetents([.large])
            #endif
        }
        .sheet(isPresented: $appState.showReplyStatsSheet) {
            ReplyStatsView(senderEmail: viewModel.senderEmail)
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #else
                .presentationDetents([.large])
                #endif
                .resizableSheet()
        }
        .sheet(isPresented: $appState.showAnalytics) {
            EmailAnalyticsView(query: modelVM.currentArchiveQuery)
                #if os(macOS)
                .resizableSheet()
                #else
                .presentationDetents([.large])
                #endif
        }
        #if !DEBUG
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
                .resizableSheet()
        }
        #endif
        .alert("Start New Import?", isPresented: $showNewImportConfirmation) {
            Button("Clear & Start Fresh", role: .destructive) {
                // Call the handler directly. On macOS, posting through
                // NotificationCenter from an alert button action proved
                // unreliable — onReceive sometimes drops the event during
                // alert dismissal. Direct invocation is synchronous and works
                // on all platforms. §11: the canonical clear (SQLite + FTS +
                // legacy stores + checkpoints + Spotlight + tombstone) runs
                // inside handleDataCleared via ArchiveLifecycleService.
                handleDataCleared()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your current emails and return to the welcome screen. You can re-import anytime.")
        }
        // Friendly import-failure alert. The parsing pipeline sets
        // viewModel.statusMessage with a human-readable message and
        // viewModel.parseErrors with file-level details. We surface it once
        // parsing has finished without yielding any emails.
        .alert("Couldn't read that file", isPresented: $showImportErrorAlert) {
            Button("OK", role: .cancel) { viewModel.parseErrors = [] }
        } message: {
            Text(importErrorMessage)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Spacing.xSmall) {
                if collabManager.isEnabled && collabManager.newImportCount > 0 {
                    collaborationBanner
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .animation(.easeInOut, value: collabManager.newImportCount)
                }
            }
            .padding(.trailing, Spacing.large)
            .padding(.top, Spacing.small)
        }
        .modifier(AdvancedFeatureSheetsModifier(
            appState: appState,
            modelVM: modelVM,
            predictiveEngine: predictiveEngine,
            custodianManager: custodianManager,
            reviewBatchManager: reviewBatchManager,
            selectedClusterFilter: $selectedClusterFilter,
            selectedEmailIDs: $selectedEmailIDs,
            exportVCard: exportVCard,
            exportICS: exportICS,
            exportHashManifest: exportHashManifest,
            batchPrintFiltered: batchPrintFiltered,
            verifyAllEmailIntegrity: verifyAllEmailIntegrity,
            exportMSG: exportMSG,
            exportPST: exportPST,
            exportRelativity: exportRelativity,
            importFromCloud: importFromCloud,
            senderEmail: viewModel.senderEmail
        ))
        .modifier(V8SheetsModifier(appState: appState, modelVM: modelVM))
        .modifier(V9SheetsModifier(appState: appState, modelVM: modelVM, senderEmail: viewModel.senderEmail))
        .sheet(isPresented: $showRemovedDuplicates) {
            RemovedDuplicatesView(findings: viewModel.removedDuplicates)
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 350)
                #else
                .presentationDetents([.large])
                #endif
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: archiveImporterTypes,
            allowsMultipleSelection: true,
            onCompletion: handleArchiveImportResult
        )
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        // The review-state importer is attached via a ViewModifier on a
        // sibling background view so it doesn't shadow the archive importer
        // above. SwiftUI on iOS only honors one .fileImporter per view.
        .modifier(ReviewImporterModifier(
            isPresented: $showReviewImporter,
            onCompletion: handleReviewImportResult
        ))
        #endif
    }

    #if os(iOS)
    private var archiveImporterTypes: [UTType] {
        [
            UTType(filenameExtension: "mbox"),
            UTType(filenameExtension: "eml"),
            UTType(filenameExtension: "emlx"),
            UTType(filenameExtension: "msg"),
            UTType(filenameExtension: "pst"),
            UTType(filenameExtension: "ost"),
            UTType(filenameExtension: "nsf"),
            UTType(filenameExtension: "zip")
        ].compactMap { $0 }
    }

    private func handleArchiveImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let resolved = resolveZipFiles(urls)
            if resolved.count == 1, let url = resolved.first {
                resolveAndHandleSelectedFile(url)
            } else if resolved.count > 1 {
                handleMultipleFiles(resolved)
            }
        case .failure:
            parseFailed = true
        }
    }

    private func handleReviewImportResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            let data = try Data(contentsOf: url)
            let importResult = try ExportManager.importReviewState(from: data, strategy: .merge)
            if importResult.total > 0 {
                viewModel.statusMessage = "Imported: \(importResult.summary)"
                viewModel.statusColor = .green
            } else {
                viewModel.statusMessage = "Review state imported — no new data (already up to date)."
                viewModel.statusColor = .blue
            }
        } catch {
            viewModel.statusMessage = "Failed to import review state: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }
    #endif

    // MARK: - Layout
    @ViewBuilder
    private var mainLayout: some View {
        #if os(macOS)
        @Bindable var appState = appState
        if modelVM.showParsedList && sidebarSelection == .emailInbox {
            emailInboxDestination
                .liquidGlassToolbar()
                .sheet(isPresented: $appState.showAuditTrail) {
                    AuditTrailSheet(forensicManager: forensicManager, onExport: { exportAuditLog() })
                        .environmentObject(storeManager)
                }
        } else {
        NavigationSplitView {
            if modelVM.showParsedList {
                hubSidebar
            } else {
                Text("Import an archive to begin")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            Group {
                if !modelVM.showParsedList {
                    WelcomeHubView(onOpenArchive: { openPanelFallback() }, onBrowseFiles: { openPanelFallback() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let dest = sidebarSelection {
                    hubDestinationView(for: dest)
                } else {
                    PersonaPickerHomeView(onSelectPersona: { persona in
                        personaManager.switchPersona(to: persona)
                        sidebarSelection = .personaHub
                    })
                }
            }
        }
        .onChange(of: sidebarSelection) { oldValue, _ in
            if isNavigatingBack {
                isNavigatingBack = false
                return
            }
            if let old = oldValue {
                navigationHistory.append(old)
                if navigationHistory.count > 20 { navigationHistory.removeFirst() }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if modelVM.showParsedList && sidebarSelection != nil {
                    Button {
                        withAnimation {
                            isNavigatingBack = true
                            if let previous = navigationHistory.popLast() {
                                sidebarSelection = previous
                            } else {
                                sidebarSelection = nil
                            }
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Back (⌘[)")
                    .keyboardShortcut("[", modifiers: .command)
                }
            }
            ToolbarItemGroup(placement: .automatic) {
                if modelVM.showParsedList {
                    Button { sidebarSelection = .emailInbox } label: {
                        Label("Inbox", systemImage: "envelope")
                    }
                    .help("Email Inbox")

                    Button {
                        if forensicManager.isEnabled {
                            forensicManager.isEnabled = false
                        } else if storeManager.requireProfessional() {
                            forensicManager.isEnabled = true
                        }
                    } label: {
                        Label("Forensic", systemImage: forensicManager.isEnabled ? "shield.checkered" : "shield")
                    }
                }
            }
        }
        .liquidGlassToolbar()
        .sheet(isPresented: $appState.showAuditTrail) {
            AuditTrailSheet(forensicManager: forensicManager, onExport: { exportAuditLog() })
                .environmentObject(storeManager)
        }
        }
        #else
        if horizontalSizeClass == .compact {
            iPhoneLayout
                .liquidGlassToolbar()
        } else {
            iPadLayout
                .liquidGlassToolbar()
        }
        #endif
    }

    // MARK: - Hub Sidebar

    private var hubSidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                Button { sidebarSelection = nil } label: {
                    Label("Home", systemImage: "house")
                }
                .foregroundColor(sidebarSelection == nil ? personaManager.selectedPersona.accentColor : .primary)
            }

            Section("Persona") {
                switch personaManager.selectedPersona {
                case .forensic:
                    sidebarRow(.forensicReview, "Forensic Review", "shield.checkered")
                case .legal:
                    sidebarRow(.legalWorkspace, "Legal Workspace", "building.columns")
                case .itAdmin:
                    sidebarRow(.itAdminDashboard, "IT Admin Analysis", "server.rack")
                case .journalist:
                    sidebarRow(.journalistWorkbench, "Investigation", "newspaper")
                case .personal:
                    sidebarRow(.personalOrganizer, "Personal Organizer", "tray.full")
                case .general:
                    sidebarRow(.generalExplorer, "Feature Explorer", "sparkles")
                }
            }

            let visibleGroups = PersonaManager.sidebarGroups(for: personaManager.selectedPersona)

            if visibleGroups.contains(.browse) {
                Section(isExpanded: $browseExpanded) {
                    sidebarRow(.emailInbox, "Email Inbox", "envelope")
                    sidebarRow(.attachmentGallery, "Attachments", "paperclip")
                    sidebarRow(.threadSummarizer, "Thread Summarizer", "text.bubble")
                    sidebarRow(.duplicateManager, "Duplicate Manager", "doc.on.doc")
                } header: {
                    Text("Browse")
                }
            }

            if visibleGroups.contains(.analysis) {
                Section(isExpanded: $analysisExpanded) {
                    sidebarRow(.emailAnalytics, "Email Analytics", "chart.bar")
                    sidebarRow(.topicClusters, "Topic Clusters", "circle.grid.3x3")
                    sidebarRow(.timeline, "Timeline", "calendar.day.timeline.left")
                    sidebarRow(.communicationPatterns, "Comm Patterns", "person.2")
                    sidebarRow(.relationshipGraph, "Relationship Graph", "point.3.connected.trianglepath.dotted")
                    sidebarRow(.executiveDashboard, "Executive Dashboard", "gauge.with.dots.needle.33percent")
                } header: {
                    Text("Analysis")
                }
            }

            if visibleGroups.contains(.security) {
                Section(isExpanded: $securityExpanded) {
                    sidebarRow(.anomalyDetection, "Anomaly Detection", "waveform.path.ecg")
                    sidebarRow(.iocExtractor, "IOC Extractor", "exclamationmark.shield")
                    sidebarRow(.smartAlerts, "Smart Alerts", "bell.badge")
                    sidebarRow(.keywordMonitor, "Keyword Monitor", "text.magnifyingglass")
                    sidebarRow(.nearDuplicates, "Near Duplicates", "square.on.square.dashed")
                } header: {
                    Text("Security")
                }
            }

            if visibleGroups.contains(.legalForensic) {
                Section(isExpanded: $legalForensicExpanded) {
                    sidebarRow(.eDiscovery, "eDiscovery", "checklist")
                    sidebarRow(.predictiveCoding, "Predictive Coding", "brain")
                    sidebarRow(.forensicReview, "Document Review", "doc.text.magnifyingglass")
                    sidebarRow(.chainOfCustody, "Chain of Custody", "link")
                    sidebarRow(.batesNumbering, "Bates Numbering", "number")
                    sidebarRow(.gdprCompliance, "GDPR Compliance", "hand.raised")
                    sidebarRow(.reviewBatches, "Review Batches", "list.bullet.rectangle")
                    sidebarRow(.custodianPanel, "Custodian Panel", "person.badge.key")
                } header: {
                    Text("Legal & Forensic")
                }
            }

            if visibleGroups.contains(.exportReports) {
                Section(isExpanded: $exportReportsExpanded) {
                    sidebarRow(.reportBuilder, "Report Builder", "doc.richtext")
                    sidebarRow(.batchOperations, "Batch Operations", "square.stack.3d.up")
                    sidebarRow(.archiveComparison, "Archive Compare", "rectangle.on.rectangle.angled")
                    sidebarRow(.investigationReport, "Investigation Report", "doc.text.magnifyingglass")
                    sidebarRow(.redaction, "Redaction", "eye.slash")
                    sidebarRow(.automationRules, "Automation Rules", "gearshape.2")
                } header: {
                    Text("Export & Reports")
                }
            }

            if visibleGroups.contains(.aiIntelligence) {
                Section(isExpanded: $aiIntelligenceExpanded) {
                    sidebarRow(.aiAssistant, "AI Assistant", "sparkles")
                    sidebarRow(.aiDigest, "AI Digest", "newspaper")
                    sidebarRow(.smartAutoTagger, "Auto-Tagger", "tag")
                    sidebarRow(.customExperts, "Custom Experts", "person.crop.rectangle.stack")
                    sidebarRow(.knowledgeGraphExplorer, "Knowledge Graph", "point.3.connected.trianglepath.dotted")
                    sidebarRow(.aiVisualizations, "AI Visualizations", "chart.bar.xaxis.ascending")
                    sidebarRow(.backgroundFindings, "Background Scan", "shield.lefthalf.filled.badge.checkmark")
                    sidebarRow(.predictiveInsights, "Predictions", "chart.line.uptrend.xyaxis")
                    sidebarRow(.pluginManager, "Plugins", "puzzlepiece.extension")
                } header: {
                    Text("AI Intelligence")
                }
            }

            Section("Help & Manage") {
                sidebarRow(.workspaceManager, "Workspaces", "square.grid.2x2")
                Button { showGlossary = true } label: {
                    Label("Glossary", systemImage: "book.closed")
                }
                .help("Plain-language definitions of legal, forensic, and technical terms.")
                .accessibilityHint("Plain-language definitions of legal, forensic, and technical terms.")
                Button { openSettingsAction() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("mailin")
        .sheet(isPresented: $showGlossary) {
            NavigationStack {
                GlossaryView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showGlossary = false }
                        }
                    }
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        .sheet(isPresented: $showGettingStarted) {
            GettingStartedView(isPresented: $showGettingStarted)
        }
    }

    private func sidebarRow(_ dest: HubDestination, _ title: String, _ icon: String) -> some View {
        let isLocked = storeManager.currentTier < dest.requiredTier
        return NavigationLink(value: dest) {
            HStack(spacing: Spacing.xSmall) {
                Label(title, systemImage: icon)
                if isLocked {
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Requires \(dest.requiredTier.displayName)")
                }
            }
        }
        .help(dest.caption)
        .accessibilityHint(dest.caption)
    }

    // MARK: - Hub Navigation

    private func handleHubNavigation(_ destination: HubDestination) {
        switch destination {
        case .settings:
            openSettingsAction()
        case .eDiscovery, .predictiveCoding, .gdprCompliance, .chainOfCustody,
             .forensicReview, .investigationReport, .batesNumbering,
             .reviewBatches, .custodianPanel, .legalWorkspace:
            if storeManager.requireProfessional() { sidebarSelection = destination }
        case .iocExtractor:
            if storeManager.requireProfessional() { sidebarSelection = destination }
        case .anomalyDetection, .smartAlerts, .keywordMonitor, .nearDuplicates,
             .emailAnalytics, .topicClusters, .timeline, .communicationPatterns,
             .relationshipGraph, .duplicateManager, .threadSummarizer,
             .attachmentGallery, .executiveDashboard, .reportBuilder,
             .batchOperations, .archiveComparison, .redaction, .automationRules,
             .aiAssistant, .aiDigest, .smartAutoTagger,
             .knowledgeGraphExplorer, .aiVisualizations, .backgroundFindings,
             .predictiveInsights, .pluginManager,
             .itAdminDashboard, .journalistWorkbench:
            if storeManager.requirePremium() { sidebarSelection = destination }
        case .emailInbox, .customExperts, .workspaceManager,
             .personalOrganizer, .generalExplorer,
             .personaHub:
            sidebarSelection = destination
        }
    }

    private func personaHubDestination(for persona: PersonaManager.Persona) -> HubDestination {
        switch persona {
        case .forensic: return .forensicReview
        case .legal: return .legalWorkspace
        case .itAdmin: return .itAdminDashboard
        case .journalist: return .journalistWorkbench
        case .personal: return .personalOrganizer
        case .general: return .generalExplorer
        }
    }

    /// Part G1: hub destinations that still take `[RawEmail]` are hosted over a
    /// bounded working set streamed from the store for the CURRENT query —
    /// never the resident preview arrays.
    private func hubWorkingSet<Content: View>(@ViewBuilder content: @escaping ([MBOXParser.RawEmail]) -> Content) -> some View {
        ArchiveWorkingSetView(query: modelVM.currentArchiveQuery, content: content)
    }

    @ViewBuilder
    private func hubDestinationView(for destination: HubDestination) -> some View {
        switch destination {
        case .emailInbox:
            emailInboxDestination

        case .eDiscovery:
            hubWorkingSet { EDiscoveryWorkflowView(emails: $0) }
                .navigationTitle("eDiscovery Workflow")
        case .predictiveCoding:
            hubWorkingSet { PredictiveCodingView(emails: $0, engine: predictiveEngine) }
                .navigationTitle("Predictive Coding")
        case .gdprCompliance:
            hubWorkingSet { GDPRReportConfigView(emails: $0) }
                .navigationTitle("GDPR Compliance")

        case .anomalyDetection:
            AnomalyDetectionView()
                .navigationTitle("Anomaly Detection")
        case .iocExtractor:
            hubWorkingSet { IOCExtractorView(emails: $0) }
                .navigationTitle("IOC Extractor")
        case .smartAlerts:
            hubWorkingSet { SmartAlertsView(emails: $0) }
                .navigationTitle("Smart Alerts")
        case .keywordMonitor:
            hubWorkingSet { KeywordMonitorView(emails: $0) }
                .navigationTitle("Keyword Monitor")
        case .nearDuplicates:
            hubWorkingSet { NearDuplicateDetectionView(emails: $0) }
                .navigationTitle("Near Duplicates")
        case .chainOfCustody:
            hubWorkingSet { ChainOfCustodyView(emails: $0) }
                .navigationTitle("Chain of Custody")

        case .emailAnalytics:
            EmailAnalyticsView()
                .navigationTitle("Email Analytics")
        case .topicClusters:
            hubWorkingSet { emails in
                TopicClustersView(
                    emails: emails,
                    selectedClusterFilter: $selectedClusterFilter,
                    clusterFilterIDs: $modelVM.clusterFilterIDs
                )
            }
            .navigationTitle("Topic Clusters")
        case .timeline:
            EmailTimelineView()
                .navigationTitle("Timeline")
        case .communicationPatterns:
            CommunicationPatternsView(senderEmail: viewModel.senderEmail)
                .navigationTitle("Communication Patterns")
        case .relationshipGraph:
            hubWorkingSet { RelationshipGraphView(emails: $0, senderEmail: viewModel.senderEmail) }
                .navigationTitle("Relationship Graph")
        case .duplicateManager:
            DuplicateManagerView(model: modelVM)
                .navigationTitle("Duplicate Manager")
        case .threadSummarizer:
            hubWorkingSet { ThreadSummarizerView(threadEmails: $0) }
                .navigationTitle("Thread Summarizer")
        case .attachmentGallery:
            hubWorkingSet { AttachmentGridView(emails: $0) }
                .navigationTitle("Attachments")
        case .executiveDashboard:
            ExecutiveDashboardView()
                .navigationTitle("Executive Dashboard")

        case .reportBuilder:
            ReportBuilderView()
                .navigationTitle("Report Builder")
        case .batchOperations:
            hubWorkingSet { emails in
                BatchOperationsView(
                    emails: emails,
                    selectedIDs: $selectedEmailIDs,
                    onTagApplied: { tag, ids in
                        let idArray = Array(ids)
                        if tag.isEmpty {
                            modelVM.review.clearAllTags(for: idArray)
                        } else {
                            modelVM.review.addTag(tag, to: idArray)
                        }
                    },
                    onExportRequested: { _, _ in
                        appState.triggerExport = true
                    }
                )
            }
            .navigationTitle("Batch Operations")
        case .archiveComparison:
            hubWorkingSet { ArchiveComparisonSheetWrapper(archiveA: $0) }
                .navigationTitle("Archive Comparison")
        case .forensicReview:
            ForensicReviewView(selectedEmailIDs: $selectedEmailIDs)
                .navigationTitle("Forensic Review")
        case .investigationReport:
            hubWorkingSet { InvestigationReportConfigSheet(emails: $0, senderEmail: viewModel.senderEmail) }
                .navigationTitle("Investigation Report")
        case .batesNumbering:
            hubWorkingSet { BatesConfigView(emails: $0) }
                .navigationTitle("Bates Numbering")
        case .redaction:
            hubWorkingSet { RedactionConfigView(emails: $0) }
                .navigationTitle("Redaction")
        case .automationRules:
            hubWorkingSet { AutomationRulesView(emails: $0) }
                .navigationTitle("Automation Rules")

        case .aiAssistant:
            AIAssistantView(
                archiveScope: currentAIScope,
                searchContext: modelVM.searchText,
                onSelectEmail: { emailID in
                    selectedEmailIDs = [emailID]
                    sidebarSelection = .emailInbox
                },
                onFilterByIDs: { ids in
                    modelVM.aiPinnedIDs = Set(ids)
                    modelVM.applyFilters()
                }
            )
            .environmentObject(storeManager)
            .navigationTitle("AI Assistant")
        case .aiDigest:
            // Zero-array digest: the generator streams a bounded working set
            // of the selected period from the store itself.
            AIDigestView()
                .navigationTitle("AI Digest")
        case .smartAutoTagger:
            SmartAutoTaggerView()
                .navigationTitle("Smart Auto-Tagger")
        case .customExperts:
            CustomExpertConfigView()
                .navigationTitle("Custom Experts")
        case .knowledgeGraphExplorer:
            hubWorkingSet { KnowledgeGraphExplorerView(emails: $0) }
                .navigationTitle("Knowledge Graph")
        case .aiVisualizations:
            hubWorkingSet { AIVisualizationDashboardView(emails: $0) }
                .navigationTitle("AI Visualizations")
        case .backgroundFindings:
            hubWorkingSet { BackgroundFindingsView(emails: $0) }
                .navigationTitle("Background Scan")
        case .predictiveInsights:
            PredictiveInsightsView()
                .navigationTitle("Predictive Insights")
        case .pluginManager:
            hubWorkingSet { PluginManagerView(emails: $0) }
                .navigationTitle("Plugin Manager")
        case .personaHub:
            MainNavigationHubView(
                // Part G3: archive total from the store count; the visible
                // filtered count describes the preview-backed list.
                emailCount: modelVM.archiveTotalCount,
                filteredCount: modelVM.displayedEmailCount,
                persona: personaManager.selectedPersona,
                onNavigate: { destination in
                    handleHubNavigation(destination)
                },
                onOpenArchive: { openPanelFallback() },
                onNewImport: { showNewImportConfirmation = true },
                onSettings: { openSettingsAction() }
            )
            .navigationTitle("\(personaManager.selectedPersona.shortLabel) Hub")
        case .reviewBatches:
            hubWorkingSet { ReviewBatchPanelView(emails: $0, manager: reviewBatchManager) }
                .navigationTitle("Review Batches")
        case .custodianPanel:
            CustodianPanelView(manager: custodianManager)
                .navigationTitle("Custodian Panel")
        case .workspaceManager:
            WorkspaceManagerView()
                .navigationTitle("Workspaces")
        case .legalWorkspace:
            LegalReviewWorkspaceView(selectedEmailIDs: $selectedEmailIDs)
                .navigationTitle("Legal Review Workspace")
        case .itAdminDashboard:
            ITAdminAnalysisView()
                .navigationTitle("IT Admin Analysis")
        case .journalistWorkbench:
            JournalistInvestigationView()
                .navigationTitle("Investigation Workbench")
        case .personalOrganizer:
            PersonalEmailOrganizerView(
                onSkipToInbox: { sidebarSelection = .emailInbox }
            )
            .navigationTitle("Personal Organizer")
        case .generalExplorer:
            GeneralAnalysisView(onNavigate: { dest in
                sidebarSelection = dest
            })
            .navigationTitle("Feature Explorer")
        case .settings:
            EmptyView()
        }
    }

    #if os(macOS)
    private var emailInboxDestination: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        sidebarSelection = nil
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 13))
                            Text("Home")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(personaManager.selectedPersona.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Back to Home")

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppColors.backgroundSecondary.opacity(0.3))
                Divider()
                leftSidebar
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
            if preferSimpleList {
                // Repository-backed bounded browse (its own list+detail split).
                ArchiveListView()
                    .frame(minWidth: 580)
            } else {
                ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
                    .frame(minWidth: 280, idealWidth: 400)
                VStack(spacing: 0) {
                    detailContentView
                    if appState.dockedBottomPanel != nil && modelVM.isParsed {
                        dockedBottomPanelView
                    }
                }
                .frame(minWidth: 300)
            }
        }
    }
    #else
    private var emailInboxDestination: some View {
        Group {
            if preferSimpleList {
                ArchiveListView()
            } else {
                ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
            }
        }
        .navigationTitle("Email Inbox")
    }
    #endif

    // MARK: - iPhone Layout (Compact)
    #if os(iOS)
    private var iPhoneLayout: some View {
        @Bindable var appState = appState
        return NavigationStack {
            Group {
                if preferSimpleList {
                    ArchiveListView()
                } else if modelVM.showParsedList {
                    ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
                } else if modelVM.isParsing || viewModel.loadingProgress > 0 {
                    iPhoneLoadingView
                } else {
                    WelcomeHubView(onOpenArchive: { openPanelFallback() }, onBrowseFiles: { showFileImporter = true })
                }
            }
            .navigationTitle(modelVM.showParsedList ? "\(modelVM.displayedEmailCount) Emails" : "mailin")
            .navigationBarTitleDisplayMode(modelVM.showParsedList ? .inline : .large)
            .toolbar {
                if modelVM.showParsedList {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            showFiltersSheet = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Filters & Tools")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.isParsed {
                        Button { appState.showAIAssistant = true } label: {
                            Image(systemName: "sparkles")
                        }
                        .accessibilityLabel("AI Assistant")

                        Menu {
                            Section("Tools") {
                                Button {
                                    if storeManager.requirePremium() {
                                        withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics }
                                    }
                                } label: {
                                    Label("Topics", systemImage: "circle.grid.3x3")
                                }
                                Button {
                                    if storeManager.requirePremium() {
                                        withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .subjects ? nil : .subjects }
                                    }
                                } label: {
                                    Label("Subjects", systemImage: "list.bullet.rectangle.portrait")
                                }
                                Button { appState.showAnalytics = true } label: {
                                    Label("Analytics", systemImage: "chart.bar")
                                }
                                Button {
                                    if forensicManager.isEnabled || storeManager.requireProfessional() {
                                        forensicManager.isEnabled.toggle()
                                    }
                                } label: {
                                    Label(
                                        forensicManager.isEnabled ? "Disable Forensic" : "Forensic Mode",
                                        systemImage: forensicManager.isEnabled ? "shield.checkered" : "shield"
                                    )
                                }
                                Button { if storeManager.requirePremium() { appState.showDuplicateManager = true } } label: {
                                    Label("Duplicates", systemImage: "doc.on.doc")
                                }
                                Button { appState.showPredictiveCoding = true } label: {
                                    Label("Predictive", systemImage: "brain")
                                }
                                Button { appState.showReplyStatsSheet = true } label: {
                                    Label("Replies", systemImage: "arrow.turn.up.left")
                                }
                                Button { appState.showArchiveComparison = true } label: {
                                    Label("Compare", systemImage: "doc.on.doc.fill")
                                }
                                Button { exportFilteredEmailsAsEML() } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                            }
                            Section("Advanced") {
                                Button { appState.showAuditTrail = true } label: {
                                    Label("Audit Trail", systemImage: "clock.arrow.circlepath")
                                }
                                Button { appState.showInvestigationReport = true } label: {
                                    Label("Report", systemImage: "doc.text.magnifyingglass")
                                }
                                Button { if storeManager.requireProfessional() { appState.showCustodianPanel = true } } label: {
                                    Label("Custodian", systemImage: "person.badge.key")
                                }
                                Button { if storeManager.requireProfessional() { appState.showReviewBatches = true } } label: {
                                    Label("Review Batches", systemImage: "list.bullet.rectangle")
                                }
                            }
                            Section {
                                Button { showNewImportConfirmation = true } label: {
                                    Label("New Import", systemImage: "house")
                                }
                                Button { openPanelFallback() } label: {
                                    Label("Add Files", systemImage: "plus")
                                }
                                Button { showIOSSettings = true } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    } else {
                        Button { showIOSSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { emailID in
                if let email = modelVM.visibleEmails.first(where: { $0.id == emailID }) {
                    EmailDetailView(
                        email: email,
                        orderedIDs: modelVM.visibleOrderedIDs,
                        onNavigate: { newID in selectedEmailIDs = [newID] },
                        onClose: { withAnimation { selectedEmailIDs = [] } },
                        searchText: modelVM.searchText
                    )
                }
            }
            .sheet(isPresented: $showFiltersSheet) {
                NavigationStack {
                    ScrollView {
                        leftSidebar
                            .padding(.horizontal, 4)
                    }
                    .navigationTitle("Filters & Tools")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showFiltersSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showIOSSettings) {
                NavigationStack {
                    SettingsView()
                        .environment(appState)
                        .environmentObject(storeManager)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showIOSSettings = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: - iPhone Welcome View
    private var iPhoneWelcomeView: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: geo.size.height * 0.08)

                    VStack(spacing: 12) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(
                                personaManager.selectedPersona.accentColor.gradient
                            )

                        Text("mailin")
                            .font(.system(.largeTitle, design: .rounded))
                            .fontWeight(.bold)

                        Text("Search, analyze, and explore\nyour email archives")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, geo.size.height * 0.05)

                    VStack(spacing: 16) {
                        TextField("Your email (optional — auto-detects)", text: $viewModel.senderEmail)
                            .font(.body)
                            .padding(12)
                            .background(Color(.tertiarySystemFill))
                            .cornerRadius(10)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)

                        Button {
                            openPanelFallback()
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                Text("Open Email Archive")
                                    .fontWeight(.semibold)
                            }
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            showFileImporter = true
                        } label: {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                Text("Browse Files")
                            }
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Toggle(isOn: $removeDuplicates) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.secondary)
                                Text("Auto-Remove on Import")
                            }
                            .font(.body)
                        }
                        .toggleStyle(.switch)
                        .help("When enabled, duplicate emails are skipped during the next import. To find duplicates in the currently loaded archive, use the Duplicate Manager from the Tools menu.")
                        .padding(.top, 4)
                    }
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .padding(.horizontal, 20)

                    if parseFailed {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Could not parse file. Try .mbox, .eml, or .zip.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: geo.size.height * 0.06)

                    VStack(spacing: 10) {
                        Text("SUPPORTED FORMATS")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(Color(.tertiaryLabel))
                            .tracking(0.5)

                        HStack(spacing: 8) {
                            ForEach(["MBOX", "EML", "EMLX", "MSG", "PST", "ZIP"], id: \.self) { fmt in
                                Text(fmt)
                                    .font(.system(.caption2, design: .monospaced))
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill))
                                    .cornerRadius(6)
                            }
                        }
                    }

                    Spacer(minLength: geo.size.height * 0.05)
                }
                .frame(minHeight: geo.size.height)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - iPhone Loading View
    private var iPhoneLoadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.8)

                if viewModel.loadingProgress > 0 {
                    VStack(spacing: 10) {
                        ProgressView(value: viewModel.loadingProgress, total: 1.0)
                            .tint(.accentColor)
                            .frame(maxWidth: 240)

                        Text("Parsing emails... \(Int(viewModel.loadingProgress * 100))%")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Preparing import...")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                if viewModel.totalParsedCount > 0 {
                    Text("\(viewModel.totalParsedCount) emails found")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }

            Spacer()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - iPad Layout (Regular)
    private var iPadLayout: some View {
        @Bindable var appState = appState
        return GeometryReader { geo in
            let totalWidth = geo.size.width
            let hasSelection = iPadSelectedEmailID != nil &&
                modelVM.visibleEmails.contains(where: { $0.id == iPadSelectedEmailID })
            let showFiltersPane = modelVM.showParsedList
            let filtersW = showFiltersPane ? totalWidth * 0.30 : 0
            let remainingW = totalWidth - filtersW
            let contentW = hasSelection ? remainingW * 0.55 : remainingW
            let detailW = remainingW * 0.45
            HStack(spacing: 0) {
                if showFiltersPane {
                    ScrollView {
                        leftSidebar
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                    }
                    .frame(width: filtersW)
                    .background(Color(.systemGroupedBackground))

                    Divider()
                }

                VStack(spacing: 0) {
                    HStack {
                        if !showFiltersPane {
                            Button { showFiltersSheet = true } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .accessibilityLabel("Filters & Tools")
                        }
                        if viewModel.isParsed {
                            Button { appState.showAIAssistant = true } label: {
                                Image(systemName: "sparkles")
                            }
                            .accessibilityLabel("AI Assistant")
                            Button { appState.showAnalytics = true } label: {
                                Image(systemName: "chart.bar")
                            }
                            .accessibilityLabel("Analytics")
                            Button {
                                if forensicManager.isEnabled || storeManager.requireProfessional() {
                                    forensicManager.isEnabled.toggle()
                                }
                            } label: {
                                Image(systemName: forensicManager.isEnabled ? "shield.checkered" : "shield")
                            }
                            .accessibilityLabel(forensicManager.isEnabled ? "Disable Forensic Mode" : "Enable Forensic Mode")
                            Button { showNewImportConfirmation = true } label: {
                                Image(systemName: "house")
                            }
                            .accessibilityLabel("New Import")
                            Menu {
                                Button {
                                    showFileImporter = true
                                } label: {
                                    Label("Add Files", systemImage: "plus")
                                }
                                Button {
                                    if storeManager.requirePremium() {
                                        appState.showDuplicateManager = true
                                    }
                                } label: {
                                    Label("Find Duplicates Now", systemImage: "doc.on.doc.fill")
                                }
                                Divider()
                                Toggle(isOn: $removeDuplicates) {
                                    Label("Auto-Remove on Import", systemImage: "doc.on.doc")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More Actions")
                        }
                        Spacer()
                        Button { showIOSSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.xxSmall)

                    if modelVM.showParsedList {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(AppColors.secondary)
                            TextField("Search emails...", text: $modelVM.searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)

                        List(modelVM.visibleEmails, id: \.id, selection: $iPadSelectedEmailID) { email in
                            EmailRowView(email: email, searchText: modelVM.searchText, showRiskIndicator: forensicManager.isEnabled)
                                .padding(.vertical, Spacing.xxxSmall)
                                .tag(email.id)
                                .onAppear { modelVM.loadMoreIfNeeded(currentID: email.id) }
                        }
                        .listStyle(.plain)
                    } else {
                        WelcomeHubView(onOpenArchive: { openPanelFallback() }, onBrowseFiles: { showFileImporter = true })
                    }
                }
                .frame(width: contentW)
                .background(Color(.systemBackground))

                if hasSelection,
                   let selectedID = iPadSelectedEmailID,
                   let email = modelVM.visibleEmails.first(where: { $0.id == selectedID }) {
                    Divider()

                    VStack(spacing: 0) {
                        EmailDetailView(
                            email: email,
                            orderedIDs: modelVM.visibleOrderedIDs,
                            onNavigate: { newID in iPadSelectedEmailID = newID },
                            onClose: { withAnimation { iPadSelectedEmailID = nil } },
                            searchText: modelVM.searchText
                        )
                        .id(selectedID)

                        if appState.dockedBottomPanel != nil && modelVM.isParsed {
                            dockedBottomPanelView
                        }
                    }
                    .frame(width: detailW)
                    .background(Color(.systemBackground))
                }
            }
            .background(Color(.systemBackground))
        }
        .onChange(of: iPadSelectedEmailID) { _, newValue in
            if let id = newValue {
                selectedEmailIDs = [id]
            } else {
                selectedEmailIDs = []
            }
        }
        .sheet(isPresented: $showIOSSettings) {
            NavigationStack {
                SettingsView()
                    .environment(appState)
                    .environmentObject(storeManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showIOSSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $appState.showAuditTrail) {
            AuditTrailSheet(forensicManager: forensicManager, onExport: { exportAuditLog() })
                .environmentObject(storeManager)
        }
        .sheet(isPresented: $showFiltersSheet) {
            NavigationStack {
                ScrollView {
                    leftSidebar
                        .padding(.horizontal, 4)
                }
                .navigationTitle("Filters & Tools")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFiltersSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
    #endif

    // MARK: - Forensic Mode Banner
    private var forensicModeBanner: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "shield.checkered")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Text("FORENSIC MODE")
                .font(.system(.caption, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.white)
                .tracking(1)

            if !forensicManager.caseNumber.isEmpty {
                Text("Case: \(forensicManager.caseNumber)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.15))
                    .cornerRadius(4)
            }

            if !forensicManager.examinerName.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                    Text(forensicManager.examinerName)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.15))
                .cornerRadius(4)
            }

            Spacer()

            if !reviewBatchManager.batches.isEmpty {
                let reviewed = reviewBatchManager.batches.reduce(0) { $0 + $1.reviewedIDs.count }
                let total = reviewBatchManager.batches.reduce(0) { $0 + $1.emailIDs.count }
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("\(reviewed)/\(total) emails reviewed")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.85))
                .help("Review progress: \(reviewed) of \(total) emails in review batches have been examined")
            }

            let taggedCount = forensicManager.evidenceTags.values.filter { $0 != .none }.count
            if taggedCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 9))
                    Text("\(taggedCount) evidence-tagged")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.85))
                .help("Emails coded with evidence tags (relevant, privileged, flagged, suspicious, etc.)")
            }

            if !forensicManager.sourceFileHashes.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                    Text("\(forensicManager.sourceFileHashes.count) source \(forensicManager.sourceFileHashes.count == 1 ? "file" : "files") hash-verified")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.85))
                .help("Imported source files with verified SHA-256 integrity hashes for chain of custody")
            }

            HStack(spacing: 3) {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 9))
                Text("\(forensicManager.auditLog.count) audit trail \(forensicManager.auditLog.count == 1 ? "action" : "actions")")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(.white.opacity(0.7))
            .help("Every action (imports, tags, annotations, exports) is logged with timestamps for legal defensibility")
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xxSmall)
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.9), Color.red.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
        )
        .adaptiveToolbarBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Forensic mode active. \(forensicManager.caseNumber.isEmpty ? "" : "Case \(forensicManager.caseNumber).") \(forensicManager.sourceFileHashes.count) source files hash-verified. \(forensicManager.auditLog.count) audit trail actions logged.")
    }

    // MARK: - Batch Operations (Multi-Select)
    private var batchOperationsView: some View {
        let selectedEmails = modelVM.visibleEmails.filter { selectedEmailIDs.contains($0.id) }
        let attachmentCount = selectedEmails.reduce(0) { $0 + $1.attachments.count }
        return VStack(spacing: Spacing.large) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .adaptiveIconGradient(colors: [AppColors.primary, AppColors.primary.opacity(0.6)])

            Text("\(selectedEmails.count) emails selected")
                .font(Typography.title2)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: Spacing.small) {
                Button {
                    exportSelectedEmails(selectedEmails)
                } label: {
                    Label("Export Selected as EML", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Export selected emails as .eml files")

                if attachmentCount > 0 {
                    Button {
                        downloadAttachmentsFromEmails(selectedEmails)
                    } label: {
                        Label("Download \(attachmentCount) Attachments", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Save all attachments from selected emails")
                }

                Button {
                    let subjects = selectedEmails.compactMap { $0.headers["Subject"] }.joined(separator: "\n")
                    PlatformClipboard.copyString(subjects)
                } label: {
                    Label("Copy Subjects", systemImage: "doc.on.doc")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Copy subject lines to clipboard")

                if showAdvancedFeatures && forensicManager.isEnabled {
                    Menu {
                        ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tag in
                            Button {
                                forensicManager.bulkTag(selectedEmailIDs, as: tag)
                            } label: {
                                Label(tag.rawValue, systemImage: tag.icon)
                            }
                        }
                    } label: {
                        Label("Bulk Evidence Tag", systemImage: "shield.checkered")
                            .frame(maxWidth: 260)
                    }
                    #if os(macOS)
                    .menuStyle(.borderedButton)
                    #endif
                }

                Button {
                    selectedEmailIDs.removeAll()
                } label: {
                    Label("Clear Selection", systemImage: "xmark.circle")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(CompactSecondaryButtonStyle())
            }
            .adaptiveCard(cornerRadius: CornerRadius.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportSelectedEmails(_ emails: [MBOXParser.RawEmail]) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder to save exported emails"
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        #else
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        #endif
        let vm = viewModel
        let isPro = storeManager.isPremium
        let limitedEmails = isPro ? emails : Array(emails.prefix(Self.freeExportLimit))
        Task.detached(priority: .userInitiated) {
            var usedNames = Set<String>()
            var exportedCount = 0
            var failedCount = 0
            var failedSubjects: [String] = []
            for (index, email) in limitedEmails.enumerated() {
                let rawSubject = email.headers["Subject"] ?? "(no-subject)"
                let safeSubject = rawSubject
                    .replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: [.regularExpression])
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(60)
                var filename = "\(index + 1)_\(safeSubject).eml"
                var counter = 1
                while usedNames.contains(filename) {
                    filename = "\(index + 1)_\(safeSubject)_\(counter).eml"
                    counter += 1
                }
                usedNames.insert(filename)
                let fileURL = folderURL.appendingPathComponent(filename)
                let emlContent = vm.exportEmailAsEML(email)
                do {
                    try FileUtils.writeData(Data(emlContent.utf8), to: fileURL.path)
                    exportedCount += 1
                } catch {
                    failedCount += 1
                    failedSubjects.append(String(rawSubject.prefix(40)))
                    FileUtilsAudit.logError(error, context: "EML Export", path: fileURL.path)
                }
            }
            let finalExported = exportedCount
            let finalFailed = failedCount
            let finalFailedSubjects = failedSubjects
            let totalSelected = emails.count
            await MainActor.run {
                if !isPro && totalSelected > finalExported {
                    vm.statusMessage = "Exported \(finalExported) of \(totalSelected) emails (free limit). Upgrade for unlimited."
                    vm.statusColor = .orange
                    self.storeManager.showPaywall = true
                } else if finalFailed > 0 {
                    let failedHint = finalFailedSubjects.prefix(3).joined(separator: ", ")
                    let moreHint = finalFailed > 3 ? " and \(finalFailed - 3) more" : ""
                    vm.statusMessage = "Exported \(finalExported) emails. \(finalFailed) failed: \(failedHint)\(moreHint)"
                    vm.statusColor = .orange
                } else {
                    vm.statusMessage = "Exported \(finalExported) emails to \(folderURL.lastPathComponent)."
                    vm.statusColor = .green
                }
                #if os(iOS)
                if finalExported > 0 {
                    self.iOSShareFile(at: folderURL)
                }
                #endif
            }
        }
    }

    private func downloadAttachmentsFromEmails(_ emails: [MBOXParser.RawEmail]) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save All"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        #else
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("attachments_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        #endif
        var usedNames = Set<String>()
        var savedCount = 0
        var failedCount = 0
        for email in emails {
            for att in email.attachments {
                guard let sourceURL = att.fileURL else { continue }
                var filename = att.filename
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: "..", with: "_")
                var counter = 1
                while usedNames.contains(filename) {
                    let name = (att.filename as NSString).deletingPathExtension
                    let ext = (att.filename as NSString).pathExtension
                    filename = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
                    counter += 1
                }
                usedNames.insert(filename)
                do {
                    try FileUtils.copyFile(from: sourceURL, to: folderURL.appendingPathComponent(filename))
                    savedCount += 1
                } catch {
                    failedCount += 1
                }
            }
        }
        if failedCount > 0 {
            viewModel.statusMessage = "Saved \(savedCount) attachments. \(failedCount) failed."
            viewModel.statusColor = .orange
        } else if savedCount > 0 {
            viewModel.statusMessage = "Saved \(savedCount) attachments to \(folderURL.lastPathComponent)."
            viewModel.statusColor = .green
        }
        #if os(iOS)
        if savedCount > 0 {
            iOSShareFile(at: folderURL)
        }
        #endif
    }

    // Inside leftSidebar view:

    private var leftSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if !modelVM.isParsed && viewModel.loadingProgress == 0 {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.title2)
                            .adaptiveIconGradient(colors: [personaManager.selectedPersona.accentColor, personaManager.selectedPersona.accentColor.opacity(0.5)])
                        VStack(alignment: .leading, spacing: 0) {
                            Text("mailin")
                                .font(.system(.headline, design: .rounded))
                                .fontWeight(.bold)
                            Text(personaManager.selectedPersona.displayName)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(personaManager.selectedPersona.accentColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Your Email Address (optional)")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        TextField("Auto-detects from archive if left blank", text: $viewModel.senderEmail)
                            .textFieldStyle(.roundedBorder)
                            .disabled(modelVM.isParsed || modelVM.isParsing)
                            .help("Optional. Helps identify sent vs received emails. If left blank, mailin will auto-detect the most common sender from your archive.")
                            .accessibilityLabel("Your email address, optional")
                            .accessibilityHint("Leave blank to auto-detect from archive, or enter your email to identify sent vs received")
                    }

                    Button {
                        openPanelFallback()
                    } label: {
                        Label("Open Email Archive", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(modelVM.isParsing)
                    .help("Supports .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf, and .zip files from Gmail, Thunderbird, Apple Mail, Outlook, Lotus Notes, and other email clients")
                    .accessibilityLabel("Open email archive")
                    .accessibilityHint("Select mbox, eml, or zip files from Gmail Takeout, Thunderbird, Apple Mail, or other email clients")

                    #if os(macOS)
                    HStack(spacing: Spacing.xSmall) {
                        Button {
                            viewModel.scanForThunderbirdProfiles()
                            if !viewModel.thunderbirdProfiles.isEmpty {
                                parseFailed = false
                                viewModel.importThunderbirdProfile(viewModel.thunderbirdProfiles)
                                showSpinner = true
                            }
                        } label: {
                            Label("Thunderbird", systemImage: "bird")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactSecondaryButtonStyle())
                        .disabled(modelVM.isParsing)
                        .help("Auto-detect and import from Thunderbird profiles")

                        Button {
                            viewModel.scanForAppleMailBoxes()
                            if !viewModel.appleMailBoxes.isEmpty {
                                handleMultipleFiles(viewModel.appleMailBoxes)
                            }
                        } label: {
                            Label("Apple Mail", systemImage: "envelope")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactSecondaryButtonStyle())
                        .disabled(modelVM.isParsing)
                        .help("Auto-detect and import from Apple Mail")
                    }
                    #endif

                    #if os(iOS)
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Browse Files", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CompactSecondaryButtonStyle())
                    .disabled(modelVM.isParsing)
                    #endif
                }

                Toggle(isOn: $removeDuplicates) {
                    Label("Auto-Remove on Import", systemImage: "doc.on.doc")
                        .font(Typography.caption1)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("When enabled, duplicate emails are skipped during the next import. To find duplicates in the currently loaded archive, tap \"Find Duplicates Now\" below.")

                if modelVM.isParsed {
                    Button {
                        if storeManager.requirePremium() {
                            appState.showDuplicateManager = true
                        }
                    } label: {
                        Label("Find Duplicates Now", systemImage: "doc.on.doc.fill")
                            .font(Typography.caption1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CompactSecondaryButtonStyle())
                    .help("Scan the currently loaded archive for duplicate emails and review/remove them.")
                }

                if modelVM.isParsed {
                    HStack(spacing: Spacing.xSmall) {
                        Button {
                            showNewImportConfirmation = true
                        } label: {
                            Label("New Import", systemImage: "house")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactSecondaryButtonStyle())
                        .accessibilityLabel("Start new import")
                        .accessibilityHint("Go back to the welcome screen to import a different archive")

                        Button {
                            openPanelFallback()
                        } label: {
                            Label("Add Files", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactSecondaryButtonStyle())
                        .accessibilityLabel("Add more email files")
                    }

                    if !storeManager.isPremium && viewModel.totalParsedCount > StoreManager.freeEmailLimit {
                        Button {
                            storeManager.showPaywall = true
                        } label: {
                            let remaining = viewModel.totalParsedCount - StoreManager.freeEmailLimit
                            HStack(spacing: Spacing.xSmall) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Free limit: \(StoreManager.freeEmailLimit) emails")
                                        .font(Typography.caption1)
                                        .fontWeight(.semibold)
                                    Text("\(remaining) more email\(remaining == 1 ? "" : "s") available with Pro")
                                        .font(Typography.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.orange)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xSmall)
                            .padding(.horizontal, Spacing.small)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(CornerRadius.medium)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: Spacing.xSmall) {
                        Text("Min Reply Count")
                            .font(Typography.caption1)
                            .fontWeight(.semibold)
                        Spacer()
                        Stepper(value: $modelVM.minReplyCount, in: 0...modelVM.maxReplyCount, step: 1) {
                            Text("\(modelVM.minReplyCount)")
                                .frame(width: 32, alignment: .center)
                        }
                        .accessibilityLabel("Minimum reply count: \(modelVM.minReplyCount)")
                        .accessibilityHint("Filter senders by minimum number of replies")
                    }
                    .help("Only show senders you've replied to at least this many times")

                    if personaManager.showSection(.summary) || personaManager.showSection(.dateRange) {
                        summarySection
                            .padding(.bottom, Spacing.xxSmall)
                    }
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.top, Spacing.small)
            .background(AppColors.backgroundPrimary)
            .zIndex(1)

            if modelVM.isParsed {
                ScrollView {
                    filterSection
                        .padding(.horizontal, Spacing.xSmall)

                    if modelVM.isParsed {
                        Divider().padding(.horizontal, Spacing.xSmall)
                        // Part G7: self-loading — archive total from the store
                        // count, buckets over a bounded working set.
                        FolderTreeView(selectedFolder: $selectedFolder)
                            .padding(.horizontal, Spacing.xSmall)
                            .onChange(of: selectedFolder) { _, newFolder in
                                if let folder = newFolder {
                                    modelVM.searchText = folder
                                } else {
                                    modelVM.searchText = ""
                                }
                            }
                    }
                }
                stickyFilterButtons
            }
        }
        #if os(macOS)
        .frame(
            minWidth: sizeClass == .compact ? 220 : 260,
            idealWidth: sizeClass == .expanded ? 320 : 280,
            maxWidth: sizeClass == .compact ? 280 : 360
        )
        #endif
    }

    // Email Action Bar (Compose / Fetch / Cloud / Reply / Reply All /
    // Forward) was removed in v2 — mailin is strictly offline by design.
    // Live-mail features now live in the separate `maxmailin` repo.

    // MARK: - Detail Placeholder with Tools

    private var compactToolsStrip: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button {
                    withAnimation { selectedEmailIDs = [] }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Close")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(AppColors.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(AppColors.secondary.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                }
                .buttonStyle(.plain)
                .padding(.leading, Spacing.small)

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xSmall) {
                        compactToolIcon("sparkles", color: .purple) { appState.showAIAssistant = true }
                        compactToolIcon("chart.bar", color: .blue) { appState.showAnalytics = true }
                        compactToolIcon("circle.grid.3x3", color: .teal) {
                            withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics }
                        }
                        compactToolIcon("list.bullet.rectangle.portrait", color: .orange) {
                            withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .subjects ? nil : .subjects }
                        }
                        compactToolIcon("doc.on.doc", color: .indigo) { if storeManager.requirePremium() { appState.showDuplicateManager = true } }
                        if isForensicPersona {
                            compactToolIcon("brain", color: .pink) { appState.showPredictiveCoding = true }
                            compactToolIcon("person.badge.key", color: .cyan) { appState.showCustodianPanel = true }
                            compactToolIcon("doc.text.magnifyingglass", color: .red) { appState.showInvestigationReport = true }
                            compactToolIcon("clock.arrow.circlepath", color: .orange) { appState.showAuditTrail = true }
                            compactToolIcon("exclamationmark.shield", color: .red) { appState.showIOCExtractor = true }
                            compactToolIcon("checklist", color: .blue) { appState.showEDiscovery = true }
                        }
                        compactToolIcon("square.and.arrow.up", color: .brown) { exportFilteredEmailsAsEML() }
                    }
                    .padding(.trailing, Spacing.small)
                }
            }
            .padding(.vertical, 5)
            .background(AppColors.backgroundSecondary.opacity(0.6))
        }
    }

    private func compactToolIcon(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 32, height: 28)
                .background(color.opacity(0.1))
                .cornerRadius(CornerRadius.small)
        }
        .buttonStyle(.plain)
    }

    private var isForensicPersona: Bool {
        let p = personaManager.selectedPersona
        return p == .forensic || p == .legal || forensicManager.isEnabled
    }

    private var detailPlaceholderWithTools: some View {
        ScrollView {
            VStack(spacing: Spacing.large) {
                Spacer(minLength: Spacing.xxLarge)

                Image(systemName: "envelope.open")
                    .font(.system(size: 40))
                    .adaptiveIconGradient(colors: [AppColors.primary.opacity(0.4), AppColors.primary.opacity(0.15)])

                VStack(spacing: Spacing.xxSmall) {
                    Text("Select an email to preview")
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.secondary)
                    Text("Click any email in the list, or use arrow keys to navigate")
                        .font(.footnote)
                        .foregroundColor(AppColors.secondary.opacity(0.6))
                }

                if modelVM.isParsed {
                    Divider().padding(.horizontal, Spacing.xxLarge)

                    // MARK: Core Tools (always visible)
                    VStack(spacing: Spacing.medium) {
                        Text("Tools")
                            .font(Typography.headline)
                            .foregroundColor(AppColors.secondary)

                        LazyVGrid(columns: [
                            GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())
                        ], spacing: Spacing.small) {
                            detailToolButton(title: "AI Assistant", icon: "sparkles", color: .purple) {
                                appState.showAIAssistant = true
                            }
                            detailToolButton(title: "Analytics", icon: "chart.bar", color: .blue) {
                                appState.showAnalytics = true
                            }
                            detailToolButton(title: "Topics", icon: "circle.grid.3x3", color: appState.dockedBottomPanel == .topics ? .teal.opacity(0.5) : .teal) {
                                withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics }
                            }
                            detailToolButton(title: "Subjects", icon: "list.bullet.rectangle.portrait", color: appState.dockedBottomPanel == .subjects ? .orange.opacity(0.5) : .orange) {
                                withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .subjects ? nil : .subjects }
                            }
                            detailToolButton(title: "Duplicates", icon: "doc.on.doc", color: .indigo) {
                                if storeManager.requirePremium() { appState.showDuplicateManager = true }
                            }
                            detailToolButton(title: "Replies", icon: "arrow.turn.up.left", color: .green) {
                                appState.showReplyStats = true
                            }
                            detailToolButton(title: "Compare", icon: "rectangle.on.rectangle.angled", color: .cyan) {
                                appState.showArchiveComparison = true
                            }
                            detailToolButton(title: "Export", icon: "square.and.arrow.up", color: .brown) {
                                exportFilteredEmailsAsEML()
                            }
                        }
                        .padding(.horizontal, Spacing.xxLarge)
                    }

                    // MARK: Forensic & Investigation Tools (persona-gated)
                    if isForensicPersona {
                        Divider().padding(.horizontal, Spacing.xxLarge)

                        VStack(spacing: Spacing.medium) {
                            HStack(spacing: Spacing.xxSmall) {
                                Image(systemName: "shield.checkered")
                                    .foregroundColor(.orange)
                                Text("Forensic & Investigation")
                                    .font(Typography.headline)
                                    .foregroundColor(AppColors.secondary)
                            }

                            LazyVGrid(columns: [
                                GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())
                            ], spacing: Spacing.small) {
                                detailToolButton(title: forensicManager.isEnabled ? "Forensic ON" : "Forensic OFF", icon: forensicManager.isEnabled ? "shield.checkered" : "shield", color: forensicManager.isEnabled ? .orange : .gray, tip: "Toggle forensic mode — enables evidence tagging, Bates numbering, and chain of custody tracking") {
                                    if forensicManager.isEnabled {
                                        forensicManager.isEnabled = false
                                    } else if storeManager.requireProfessional() {
                                        forensicManager.isEnabled = true
                                    }
                                }
                                detailToolButton(title: "e-Discovery", icon: "checklist", color: .blue, tip: "Manage legal discovery workflows — search, review, and produce documents for litigation") {
                                    if storeManager.requireProfessional() { appState.showEDiscovery = true }
                                }
                                detailToolButton(title: "Chain of Custody", icon: "link", color: .orange, tip: "Track who accessed, modified, or exported evidence and when") {
                                    if storeManager.requireProfessional() { appState.showChainOfCustody = true }
                                }
                                detailToolButton(title: "Audit Trail", icon: "clock.arrow.circlepath", color: .orange, tip: "View a complete log of all review actions taken on documents") {
                                    if storeManager.requireProfessional() { appState.showAuditTrail = true }
                                }
                                detailToolButton(title: "IOC Extractor", icon: "exclamationmark.shield", color: .red, tip: "Extract Indicators of Compromise — suspicious IPs, URLs, domains, and file hashes from emails") {
                                    if storeManager.requireProfessional() { appState.showIOCExtractor = true }
                                }
                                detailToolButton(title: "Anomalies", icon: "waveform.path.ecg", color: .red, tip: "Detect unusual patterns — odd sending times, frequency spikes, or behavioral changes") {
                                    if storeManager.requirePremium() { appState.showAnomalyDetection = true }
                                }
                                detailToolButton(title: "Keyword Monitor", icon: "text.magnifyingglass", color: .teal, tip: "Set up keyword alerts to flag emails containing specific terms") {
                                    if storeManager.requirePremium() { appState.showKeywordMonitor = true }
                                }
                                detailToolButton(title: "Near Duplicates", icon: "square.on.square.dashed", color: .indigo, tip: "Find emails that are almost identical — catches forwarded, replied, or slightly edited copies") {
                                    if storeManager.requirePremium() { appState.showNearDuplicates = true }
                                }
                                detailToolButton(title: "Predictive Coding", icon: "brain", color: .pink, tip: "AI-assisted document review — learns from your tagging to suggest relevant documents") {
                                    if storeManager.requireProfessional() { appState.showPredictiveCoding = true }
                                }
                                detailToolButton(title: "Review Batches", icon: "list.bullet.rectangle", color: .mint, tip: "Organize emails into review batches for systematic team review") {
                                    if storeManager.requireProfessional() { appState.showReviewBatches = true }
                                }
                                detailToolButton(title: "Custodians", icon: "person.badge.key", color: .cyan, tip: "Manage custodians — the people responsible for the documents under review") {
                                    if storeManager.requireProfessional() { appState.showCustodianPanel = true }
                                }
                                detailToolButton(title: "Bates Numbers", icon: "number", color: .purple, tip: "Assign unique tracking numbers to documents for legal reference") {
                                    if storeManager.requireProfessional() { appState.showBatesNumbering = true }
                                }
                                detailToolButton(title: "Report Builder", icon: "doc.text.magnifyingglass", color: .red, tip: "Generate investigation reports with findings, timelines, and evidence summaries") {
                                    if storeManager.requireProfessional() { appState.showInvestigationReport = true }
                                }
                                detailToolButton(title: "GDPR Report", icon: "hand.raised", color: .green, tip: "Generate data privacy compliance reports for GDPR and similar regulations") {
                                    if storeManager.requireProfessional() { appState.showGDPRReport = true }
                                }
                                detailToolButton(title: "Redaction", icon: "eye.slash", color: .gray, tip: "Mark sensitive information for redaction before producing documents") {
                                    if storeManager.requirePremium() { appState.showRedaction = true }
                                }
                                detailToolButton(
                                    title: storeManager.isPremium ? storeManager.currentTier.displayName : "Upgrade",
                                    icon: storeManager.isPremium ? "crown.fill" : "crown",
                                    color: .orange
                                ) {
                                    storeManager.showPaywall = true
                                }
                            }
                            .padding(.horizontal, Spacing.xxLarge)
                        }
                    }
                }

                // Persona selector hidden for Personal persona to keep the
                // email explorer focused. Switch personas via Settings or the
                // workspace picker on Home.
                if personaManager.selectedPersona != .personal {
                    Divider().padding(.horizontal, Spacing.xxLarge)

                    VStack(spacing: Spacing.medium) {
                        Text("Persona")
                            .font(Typography.headline)
                            .foregroundColor(AppColors.secondary)

                        LazyVGrid(columns: [
                            GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: Spacing.small) {
                            ForEach(PersonaManager.Persona.pickableCases, id: \.self) { persona in
                                personaButton(persona)
                            }
                        }
                        .padding(.horizontal, Spacing.xxLarge)
                    }
                }

                Divider().padding(.horizontal, Spacing.xxLarge)

                // Quick Settings
                VStack(spacing: Spacing.medium) {
                    Text("Settings")
                        .font(Typography.headline)
                        .foregroundColor(AppColors.secondary)

                    LazyVGrid(columns: [
                        GridItem(.flexible()), GridItem(.flexible()),
                        GridItem(.flexible()), GridItem(.flexible())
                    ], spacing: Spacing.small) {
                        detailToolButton(title: "Preferences", icon: "gearshape", color: .gray) {
                            openSettingsAction()
                        }
                        detailToolButton(title: "What's New", icon: "sparkles.rectangle.stack", color: .purple) {
                            appState.showWhatsNew = true
                        }
                        detailToolButton(title: "Shortcuts", icon: "keyboard", color: .gray) {
                            appState.showKeyboardShortcuts = true
                        }
                        detailToolButton(title: "Commands", icon: "terminal", color: .indigo) {
                            appState.showCommandPalette = true
                        }
                    }
                    .padding(.horizontal, Spacing.xxLarge)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailToolButton(title: String, icon: String, color: Color, tip: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxSmall) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, Spacing.small)
            .background(color.opacity(0.06))
            .cornerRadius(CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(tip ?? title)
    }

    @ViewBuilder
    private func personaButton(_ persona: PersonaManager.Persona) -> some View {
        let isSelected = personaManager.selectedPersona == persona
        Button {
            if isSelected {
                personaManager.switchPersona(to: .personal)
            } else {
                personaManager.switchPersona(to: persona)
            }
        } label: {
            VStack(spacing: Spacing.xxSmall) {
                Image(systemName: persona.icon)
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .white : persona.accentColor)
                Text(persona.shortLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? .white : AppColors.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.small)
            .background(isSelected ? persona.accentColor : persona.accentColor.opacity(0.06))
            .cornerRadius(CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(persona.displayName)\(isSelected ? ", selected" : "")")
    }

    private func openSettingsAction() {
        #if os(macOS)
        openSettings()
        #else
        showIOSSettings = true
        #endif
    }

    // MARK: - Docked Bottom Panel (Topics / Subjects)
    // Part G1: docked panels stream their own bounded working set for the
    // current query — never the resident preview arrays.

    @ViewBuilder
    private var dockedBottomPanelView: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            dockedPanelDragHandle
            dockedPanelTabBar
            Divider()

            Group {
                switch appState.dockedBottomPanel {
                case .topics:
                    ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                        TopicClustersView(
                            emails: emails,
                            selectedClusterFilter: $selectedClusterFilter,
                            clusterFilterIDs: $modelVM.clusterFilterIDs
                        )
                    }
                case .subjects:
                    ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                        SubjectsListView(
                            emails: emails,
                            clusterFilterIDs: $modelVM.clusterFilterIDs
                        )
                    }
                case .none:
                    EmptyView()
                }
            }
            .frame(height: max(bottomPanelHeight - 40, 100))
        }
        .background(AppColors.backgroundPrimary)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var dockedPanelDragHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppColors.secondary.opacity(0.3))
                    .frame(width: 36, height: 4)
            )
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        bottomPanelHeight = max(120, min(600, dragStartHeight - value.translation.height))
                    }
                    .onEnded { _ in
                        dragStartHeight = bottomPanelHeight
                    }
            )
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
    }

    private var dockedPanelTabBar: some View {
        @Bindable var appState = appState
        return HStack(spacing: 0) {
            dockedTabButton(
                title: "Topics",
                icon: "circle.grid.3x3",
                isActive: appState.dockedBottomPanel == .topics
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { appState.dockedBottomPanel = .topics }
            }

            dockedTabButton(
                title: "Subjects",
                icon: "list.bullet.rectangle.portrait",
                isActive: appState.dockedBottomPanel == .subjects
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { appState.dockedBottomPanel = .subjects }
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.dockedBottomPanel = nil
                    modelVM.clusterFilterIDs = nil
                    selectedClusterFilter = nil
                    modelVM.applyFilters()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppColors.secondary)
                    .padding(6)
                    .background(AppColors.secondary.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close panel")
            .padding(.trailing, Spacing.small)
        }
        .padding(.leading, Spacing.small)
        .background(AppColors.backgroundSecondary)
    }

    private func dockedTabButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(Typography.caption1)
                    .fontWeight(isActive ? .semibold : .regular)
            }
            .foregroundColor(isActive ? AppColors.primary : AppColors.secondary)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 6)
            .background(isActive ? AppColors.primary.opacity(0.1) : Color.clear)
            .cornerRadius(CornerRadius.small)
        }
        .buttonStyle(.plain)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
            if viewModel.duplicatesRemoved > 0 && personaManager.showSection(.summary) {
                Button {
                    showRemovedDuplicates = true
                } label: {
                    HStack(spacing: Spacing.xxSmall) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(Typography.caption2)
                        Text("\(viewModel.duplicatesRemoved) duplicates removed")
                            .font(Typography.caption2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(AppColors.info)
                }
                .buttonStyle(.plain)
                .help("View removed duplicates")
            }
            HStack(spacing: Spacing.small) {
                // Part G3: unfiltered → store-backed archive total; filtered →
                // the visible (preview-backed) list count.
                Label("\(modelVM.displayedEmailCount) Emails", systemImage: "chart.bar.fill")
                    .font(Typography.title3)
                    .foregroundColor(AppColors.secondary)
                    .contentTransition(.numericText())
                    .adaptiveAnimation(modelVM.displayedEmailCount)
                if modelVM.aiPinnedIDs != nil {
                    Button {
                        modelVM.aiPinnedIDs = nil
                        modelVM.applyFilters()
                    } label: {
                        Label("AI Filter", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)))
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear AI filter")
                }
                Spacer()
                if let start = modelVM.filteredDateRange.0, let end = modelVM.filteredDateRange.1 {
                    Text("\(formatted(start)) – \(formatted(end))")
                        .font(Typography.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.info)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(Spacing.xxSmall)
                }
            }
            if personaManager.showSection(.dateRange) {
                HStack(spacing: Spacing.xSmall) {
                    ModernDateField(label: "Start date filter", date: $modelVM.startDate)
                        .onChange(of: modelVM.startDate) { _, _ in modelVM.dateBoundsChanged() }
                    Text("–")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    ModernDateField(label: "End date filter", date: $modelVM.endDate)
                        .onChange(of: modelVM.endDate) { _, _ in modelVM.dateBoundsChanged() }
                    Spacer()
                }
            }
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Divider()

            if personaManager.showSection(.senders) {
                SidebarSectionHeader(title: "From (Senders)", icon: "arrow.up.forward", color: AppColors.sentEmail, helpText: "Filter emails by sender address")
                multiToggleList(items: modelVM.allFromEmails, selection: $modelVM.selectedFromEmails)
            }

            if personaManager.showSection(.recipients) {
                SidebarSectionHeader(title: "To (Recipients)", icon: "arrow.down.backward", color: AppColors.receivedEmail, helpText: "Filter emails by recipient address")
                multiToggleList(items: modelVM.allToEmails, selection: $modelVM.selectedToEmails)
            }

            if !modelVM.allTags.isEmpty && personaManager.showSection(.labels) {
                SidebarSectionHeader(title: "Labels", icon: "tag", color: .purple, helpText: "Filter emails by Gmail labels or tags")
                multiToggleList(items: modelVM.allTags, selection: $modelVM.selectedTags)
            }

            if !modelVM.smartTagCounts.isEmpty {
                SidebarSectionHeader(title: "Smart Tags", icon: "tag.fill", color: .purple, helpText: "Filter by AI-detected category, priority, sentiment, or forensic tag")
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    ForEach(modelVM.smartTagCounts, id: \.tag) { entry in
                        Button {
                            if modelVM.selectedSmartTags.contains(entry.tag) {
                                modelVM.selectedSmartTags.remove(entry.tag)
                            } else {
                                modelVM.selectedSmartTags.insert(entry.tag)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: entry.tag.icon)
                                    .font(.caption2)
                                    .foregroundColor(entry.tag.color)
                                Text(entry.tag.rawValue)
                                    .font(Typography.caption1)
                                Spacer()
                                Text("\(entry.count)")
                                    .font(Typography.caption2)
                                    .foregroundColor(.secondary)
                                if modelVM.selectedSmartTags.contains(entry.tag) {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundColor(.purple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.tag.rawValue), \(entry.count) emails\(modelVM.selectedSmartTags.contains(entry.tag) ? ", selected" : "")")
                    }
                    if !modelVM.selectedSmartTags.isEmpty {
                        Button {
                            modelVM.selectedSmartTags.removeAll()
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle")
                                    .font(.caption2)
                                Text("Clear Tag Filters")
                                    .font(Typography.caption2)
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if forensicManager.isEnabled || personaManager.selectedPersona == .legal || personaManager.selectedPersona == .forensic {
                SidebarSectionHeader(title: "Evidence Tags", icon: "shield.checkered", color: .orange, helpText: "Filter by forensic evidence tag")
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Button {
                        modelVM.selectedEvidenceTag = nil
                        modelVM.applyFilters()
                    } label: {
                        HStack {
                            Text("All Emails")
                                .font(Typography.caption1)
                            Spacer()
                            if modelVM.selectedEvidenceTag == nil {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all emails")
                    .accessibilityAddTraits(modelVM.selectedEvidenceTag == nil ? .isSelected : [])

                    let tagsWithCounts = ForensicManager.EvidenceTag.allCases.filter { $0 != .none }.map { ($0, forensicManager.taggedCount(for: $0)) }
                    let hasAnyTags = tagsWithCounts.contains { $0.1 > 0 }

                    if hasAnyTags {
                        ForEach(tagsWithCounts.filter { $0.1 > 0 }, id: \.0) { tag, count in
                            Button {
                                modelVM.selectedEvidenceTag = tag
                                modelVM.applyFilters()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: tag.icon)
                                        .font(.caption2)
                                        .foregroundColor(tag.color)
                                    Text(tag.rawValue)
                                        .font(Typography.caption1)
                                    Spacer()
                                    Text("\(count)")
                                        .font(Typography.caption2)
                                        .foregroundColor(.secondary)
                                    if modelVM.selectedEvidenceTag == tag {
                                        Image(systemName: "checkmark")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Filter by \(tag.rawValue), \(count) emails")
                            .accessibilityAddTraits(modelVM.selectedEvidenceTag == tag ? .isSelected : [])
                        }
                    } else {
                        Text("Right-click emails to assign evidence tags")
                            .font(Typography.caption2)
                            .foregroundColor(.secondary)
                            .padding(.vertical, Spacing.xxSmall)
                    }
                }
            }

            if !modelVM.sortedSendersByReplyCount.isEmpty && personaManager.showSection(.replyFrequency) {
                SidebarSectionHeader(title: "Reply Frequency", icon: "envelope.arrow.triangle.branch", color: AppColors.primary, helpText: "Senders ranked by how often you replied to them")
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        ForEach(modelVM.sortedSendersByReplyCount, id: \.email) { entry in
                            HStack {
                                Text(entry.email.prefix(38))
                                    .font(Typography.caption1)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(entry.count)")
                                    .font(Typography.caption1)
                                    .fontWeight(.medium)
                                    .foregroundColor(AppColors.primary)
                                    .padding(.horizontal, Spacing.xxSmall)
                                    .padding(.vertical, 1)
                                    .background(AppColors.primary.opacity(0.1))
                                    .cornerRadius(CornerRadius.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }

            if !modelVM.allDomains.isEmpty && personaManager.showSection(.domains) {
                SidebarSectionHeader(title: "Domains", icon: "globe", color: .teal, helpText: "Filter emails by sender/recipient domain")
                multiToggleList(items: modelVM.allDomains, selection: $modelVM.selectedDomains)
            }
        }
    }

    private var stickyFilterButtons: some View {
        VStack(spacing: Spacing.xSmall) {
            HStack(spacing: Spacing.xSmall) {
                Button {
                    modelVM.applyFilters()
                } label: {
                    Label("Apply", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CompactPrimaryButtonStyle())
                .help("Apply the selected filters to your email list")
                .accessibilityLabel("Apply filters")

                Button {
                    modelVM.resetFilters()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CompactSecondaryButtonStyle())
                .help("Reset all filters and show all emails")
                .accessibilityLabel("Clear all filters")
            }

            Menu {
                // THE unified format list — identical to the list footer's
                // Export menu and the open-email export menu.
                UnifiedExportSections(
                    scope: { filteredScope },
                    emlRender: { viewModel.exportEmailAsEML($0) },
                    share: { url in
                        #if os(iOS)
                        iOSShareFile(at: url)
                        #endif
                    },
                    errorMessage: $sidebarExportError
                )
                .environmentObject(storeManager)
            } label: {
                Label("Export Emails", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .help("Export filtered emails — documents, per-email files, contacts, events")
            .accessibilityLabel("Export filtered emails")
            .alert("Export Error", isPresented: Binding(
                get: { sidebarExportError != nil },
                set: { if !$0 { sidebarExportError = nil } }
            )) {
                Button("OK") { sidebarExportError = nil }
            } message: {
                Text(sidebarExportError ?? "An unknown error occurred.")
            }

            if showAdvancedFeatures && (forensicManager.isEnabled || personaManager.selectedPersona == .legal) {
                let isLegalOnly = !forensicManager.isEnabled && personaManager.selectedPersona == .legal
                let menuLabel = isLegalOnly ? "Production Export" : "Forensic Export"
                let menuIcon = isLegalOnly ? "building.columns" : "shield.checkered"
                Menu {
                    Section("Evidence") {
                        Button {
                            if storeManager.requireProfessional() { exportBulkForensicCSV() }
                        } label: {
                            Label(storeManager.isProfessional ? "Bates CSV (numbered + hashes)" : "Bates CSV (Pro)", systemImage: "tablecells")
                        }
                        Button {
                            if storeManager.requireProfessional() { exportConcordanceDAT() }
                        } label: {
                            Label("Concordance Load File (.dat)", systemImage: "doc.text")
                        }
                        if !forensicManager.evidenceTags.isEmpty {
                            Button {
                                exportTaggedOnly()
                            } label: {
                                Label("Export Tagged Emails Only", systemImage: "checkmark.seal")
                            }
                        }
                    }
                    if forensicManager.isEnabled {
                        Section("Integrity") {
                            Button {
                                if storeManager.requireProfessional() { exportHashManifest() }
                            } label: {
                                Label("Hash Manifest (CSV)", systemImage: "number.square")
                            }
                            Button {
                                if storeManager.requireProfessional() { verifyAllEmailIntegrity() }
                            } label: {
                                Label("Verify All Email Integrity", systemImage: "checkmark.shield")
                            }
                        }
                    }
                    Section("Reports") {
                        if forensicManager.isEnabled {
                            Button {
                                if storeManager.requireProfessional() { exportAuditLog() }
                            } label: {
                                Label(storeManager.isProfessional ? "Audit Log (tamper-evident)" : "Audit Log (Pro)", systemImage: "list.bullet.rectangle")
                            }
                        }
                        Button {
                            exportPrivilegeLog()
                        } label: {
                            Label("Privilege Log", systemImage: "building.columns.fill")
                        }
                        Button {
                            appState.showInvestigationReport = true
                        } label: {
                            Label("Investigation Report (PDF)", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            appState.showCustodianPanel = true
                        } label: {
                            Label("Custodian Manager", systemImage: "person.badge.shield.checkmark")
                        }
                        Button {
                            if storeManager.requireProfessional() {
                                appState.showReviewBatches = true
                            }
                        } label: {
                            Label(storeManager.isProfessional ? "Review Batches" : "Review Batches (Pro)", systemImage: "rectangle.stack.badge.play")
                        }
                    }
                    Section("Review Sharing") {
                        Button {
                            if storeManager.requireProfessional() { exportReviewState() }
                        } label: {
                            Label(storeManager.isProfessional ? "Export Review State" : "Export Review State (Pro)", systemImage: "square.and.arrow.up.on.square")
                        }
                        Button {
                            if storeManager.requireProfessional() { importReviewState() }
                        } label: {
                            Label(storeManager.isProfessional ? "Import Review State" : "Import Review State (Pro)", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                } label: {
                    Label(menuLabel, systemImage: menuIcon)
                        .frame(maxWidth: .infinity)
                }
                #if os(macOS)
                .menuStyle(.borderedButton)
                #endif
                .controlSize(.small)
                .help(isLegalOnly ? "Export production sets: Bates-numbered CSV, Concordance load files, and tagged documents" : "Export forensic data: CSV with Bates numbers and hashes, Concordance load files, or the tamper-evident audit log")
                .accessibilityLabel(isLegalOnly ? "Production export options" : "Forensic export options")
            }
        }
        .padding(.vertical, Spacing.small)
        .padding(.horizontal, Spacing.xSmall)
        .adaptiveToolbarBackground()
    }

    @ViewBuilder
    private var detailContentView: some View {
        @Bindable var appState = appState
        if !modelVM.showParsedList {
            WelcomeHubView(onOpenArchive: { openPanelFallback() }, onBrowseFiles: { openPanelFallback() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedEmailIDs.count == 1,
                  let selectedID = selectedEmailIDs.first {
            if let email = modelVM.visibleEmails.first(where: { $0.id == selectedID }) {
                EmailDetailView(
                    email: email,
                    orderedIDs: modelVM.visibleOrderedIDs,
                    onNavigate: { newID in selectedEmailIDs = [newID] },
                    onClose: { withAnimation { selectedEmailIDs = [] } },
                    searchText: modelVM.searchText
                )
                .id(selectedID)
                .onAppear { modelVM.markRead(selectedID) }
                compactToolsStrip
            }
        } else if selectedEmailIDs.count == 2 {
            let pair = Array(selectedEmailIDs)
            let emailA = pair.count > 0 ? modelVM.visibleEmails.first(where: { $0.id == pair[0] }) : nil
            let emailB = pair.count > 1 ? modelVM.visibleEmails.first(where: { $0.id == pair[1] }) : nil
            if let a = emailA, let b = emailB {
                VStack(spacing: 0) {
                    HStack {
                        Text("Comparing 2 emails")
                            .font(Typography.headline)
                        Spacer()
                        Button("Show Batch Actions") {
                            appState.showBatchOperations = true
                        }
                        .buttonStyle(CompactSecondaryButtonStyle())
                    }
                    .padding(Spacing.small)
                    EmailComparisonView(emailA: a, emailB: b)
                }
            } else {
                batchOperationsView
            }
        } else if selectedEmailIDs.count > 1 {
            batchOperationsView
        } else {
            detailPlaceholderWithTools
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: sizeClass == .compact ? Spacing.small : Spacing.large) {
            Spacer()

            PlatformApp.appIconImage
                .resizable()
                .scaledToFit()
                .frame(width: sizeClass == .compact ? 64 : 96, height: sizeClass == .compact ? 64 : 96)
                .shadow(color: .black.opacity(0.12), radius: Shadows.large.radius, y: Shadows.large.y)

            VStack(spacing: Spacing.xSmall) {
                Text(personaManager.config.welcomeTitle)
                    .font(.system(sizeClass == .compact ? .title3 : .title, design: .rounded))
                    .fontWeight(.bold)

                Text(personaManager.config.emptyStateMessage)
                    .font(sizeClass == .compact ? Typography.callout : Typography.body)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: sizeClass == .compact ? Spacing.xSmall : Spacing.medium) {
                Text("Get Started")
                    .font(Typography.headline)
                    .foregroundColor(AppColors.primary)

                onboardingStep(number: "1", icon: "folder.badge.plus", title: "Import an archive", subtitle: sizeClass == .compact ? nil : "Open .mbox, .eml, or .zip files from Gmail Takeout, Thunderbird, Apple Mail, Outlook, Postbox, and more")
                onboardingStep(number: "2", icon: "at", title: "Enter your email (optional)", subtitle: sizeClass == .compact ? nil : "Helps identify sent vs received. Leave blank and mailin will auto-detect from your archive.")
                onboardingStep(number: "3", icon: "line.3.horizontal.decrease.circle", title: personaStep3Title, subtitle: sizeClass == .compact ? nil : personaStep3Subtitle)
                onboardingStep(number: "4", icon: personaStep4Icon, title: personaStep4Title, subtitle: sizeClass == .compact ? nil : personaStep4Subtitle)
            }
            .padding(sizeClass == .compact ? Spacing.medium : Spacing.large)
            .adaptiveGlass(in: .rect(cornerRadius: CornerRadius.large))

            TipView(ImportEmailsTip(), arrowEdge: .top)
                .padding(.horizontal, Spacing.large)

            if sizeClass != .compact {
                VStack(spacing: Spacing.small) {
                    HStack(spacing: Spacing.large) {
                        ForEach(personaFeatureBadges, id: \.text) { badge in
                            FeatureBadge(icon: badge.icon, text: badge.text, color: badge.color)
                        }
                    }

                    Text(personaPrivacyNote)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "keyboard")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Text("Tip: Use")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                Text("\u{2318}O")
                    .font(Typography.monoSmall)
                    .fontWeight(.semibold)
                    .padding(.horizontal, Spacing.xxSmall)
                    .padding(.vertical, 1)
                    .background(AppColors.backgroundSecondary)
                    .cornerRadius(CornerRadius.small)
                Text("to quickly open an email archive")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }

            // Sample data shortcut — lets new users (and App Store reviewers)
            // experience the app without needing an external archive.
            Button {
                loadSampleData()
            } label: {
                Label("Try with Sample Data", systemImage: "wand.and.stars")
                    .font(Typography.callout)
                    .fontWeight(.medium)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, Spacing.xSmall)
            }
            .buttonStyle(.bordered)
            .help("Load 25 example emails so you can explore search, tags, and analytics without importing a file.")
            .accessibilityHint("Loads 25 fictional sample emails so you can try the app right away.")

            Text("Sample data is fictional and clearly tagged. Remove anytime.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary.opacity(0.7))

            Spacer()
        }
        .frame(maxWidth: sizeClass == .compact ? 350 : 560)
        .adaptiveHeroBackground()
    }

    /// Part D: the AI assistant consumes scope semantics (query + selected ids)
    /// instead of corpus arrays. Maps the current legacy filter state onto the
    /// bounded archive query (text + date bounds — the fields `EmailQuery`
    /// resolves today).
    private var currentAIScope: AIAssistantScope {
        var query = EmailQuery.all
        let text = modelVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { query.text = text }
        if modelVM.startDate > .distantPast { query.afterDate = modelVM.startDate }
        if modelVM.endDate < .distantFuture { query.beforeDate = modelVM.endDate }
        return AIAssistantScope(filteredQuery: query, selectedIDs: Array(selectedEmailIDs))
    }

    /// Loads bundled fictional sample emails so users can experience the app
    /// without needing an external archive. Tagged with `SampleData.sampleTag`
    /// so they can be filtered or removed later.
    private func loadSampleData() {
        // Part Q: samples are persisted into the SQLite authority + FTS like
        // any other import — no in-RAM corpus, no v1 JSON writes. `ingestEmails`
        // posts `.parsingFinished`, which re-pages the list surfaces.
        Task { @MainActor in
            await viewModel.ingestEmails(SampleData.emails(), sourceLabel: "sample data")
        }
    }

    private func onboardingStep(number: String, icon: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: icon)
                .font(Typography.callout)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(colors: [AppColors.primary, AppColors.primary.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text(title)
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)\(subtitle.map { ". \($0)" } ?? "")")
    }

    private func multiToggleList(items: [String], selection: Binding<[String]>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                ForEach(items, id: \.self) { item in
                    Toggle(isOn: Binding(
                        get: { selection.wrappedValue.contains(item) },
                        set: { isOn in
                            if isOn {
                                selection.wrappedValue.append(item)
                            } else {
                                selection.wrappedValue.removeAll { $0 == item }
                            }
                            modelVM.applyFilters()
                        }
                    )) {
                        Text(item.prefix(38)).font(Typography.caption1)
                    }
                }
            }
        }
        .frame(maxHeight: 90)
    }

    private var overlaySpinner: some View {
        ZStack {
            #if os(macOS)
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
            #else
            VisualEffectBlur()
                .edgesIgnoringSafeArea(.all)
            #endif
            VStack(spacing: Spacing.medium) {
                ProgressView(value: viewModel.loadingProgress)
                    .scaleEffect(1.6)
                    .progressViewStyle(CircularProgressViewStyle(tint: AppColors.primary))
                    .shadow(radius: Shadows.medium.radius)
                Text(viewModel.loadingText.isEmpty
                    ? (parseFailed ? "Failed to parse file." : "Parsing .mbox file…")
                    : viewModel.loadingText)
                    .foregroundColor(.primary)
                    .font(Typography.headline)
                if viewModel.loadingProgress > 0.01 && viewModel.loadingProgress < 0.99 {
                    Text("\(Int(viewModel.loadingProgress * 100))% complete")
                        .foregroundColor(AppColors.secondary)
                        .font(Typography.subheadline)
                }
                if viewModel.memoryUsageMB > 0 {
                    Text("Memory: \(String(format: "%.0f", viewModel.memoryUsageMB)) MB")
                        .font(Typography.caption1)
                        .foregroundColor(viewModel.memoryUsageMB > 2000 ? AppColors.warning : AppColors.secondary)
                }
            }
            .padding(Spacing.xLarge)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xLarge)
                    .fill(AppColors.backgroundPrimary.opacity(0.97))
                    .shadow(radius: Shadows.xLarge.radius)
            )
        }
        .zIndex(99)
    }

    // MARK: - Persona-Adaptive UI

    private struct BadgeInfo: Hashable {
        let icon: String
        let text: String
        let color: Color

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
        }
        static func == (lhs: BadgeInfo, rhs: BadgeInfo) -> Bool {
            lhs.text == rhs.text
        }
    }

    private var personaFeatureBadges: [BadgeInfo] {
        switch personaManager.selectedPersona {
        case .forensic:
            return [
                BadgeInfo(icon: "lock.shield.fill", text: "On-Device Only", color: .green),
                BadgeInfo(icon: "checkmark.seal.fill", text: "Tamper-Proof", color: .orange),
                BadgeInfo(icon: "doc.badge.gearshape", text: "Court-Ready", color: .blue)
            ]
        case .legal:
            return [
                BadgeInfo(icon: "lock.shield.fill", text: "Privilege-Safe", color: .indigo),
                BadgeInfo(icon: "number.square", text: "Bates Numbering", color: .blue),
                BadgeInfo(icon: "doc.text.magnifyingglass", text: "Full-Text Search", color: .purple)
            ]
        case .itAdmin:
            return [
                BadgeInfo(icon: "network", text: "Header Analysis", color: .teal),
                BadgeInfo(icon: "shield.checkered", text: "Auth Verification", color: .blue),
                BadgeInfo(icon: "doc.zipper", text: "Batch Export", color: .green)
            ]
        case .journalist:
            return [
                BadgeInfo(icon: "brain.head.profile", text: "AI Analysis", color: .purple),
                BadgeInfo(icon: "chart.line.uptrend.xyaxis", text: "Pattern Discovery", color: .blue),
                BadgeInfo(icon: "lock.shield.fill", text: "Source Protection", color: .green)
            ]
        case .personal:
            return [
                BadgeInfo(icon: "gift.fill", text: "Free to Try", color: .green),
                BadgeInfo(icon: "lock.shield.fill", text: "100% Private", color: .blue),
                BadgeInfo(icon: "brain.head.profile", text: "On-Device AI", color: .purple)
            ]
        case .general:
            return [
                BadgeInfo(icon: "lock.shield.fill", text: "100% Private", color: .blue),
                BadgeInfo(icon: "brain.head.profile", text: "AI Insights", color: .purple),
                BadgeInfo(icon: "chart.bar.fill", text: "Analytics", color: .mint)
            ]
        }
    }

    private var personaPrivacyNote: String {
        switch personaManager.selectedPersona {
        case .forensic: return "All processing stays on-device. Cloud AI is disabled in forensic mode to maintain chain of custody."
        case .legal: return "Documents never leave your Mac. Privilege review stays confidential."
        case .itAdmin: return "All header analysis happens locally. No email content is transmitted externally."
        case .journalist: return "Source material stays on your Mac. No data is shared with external servers."
        case .personal, .general: return "No data ever leaves your device. All analysis is performed locally."
        }
    }

    // MARK: - Persona-Adaptive Onboarding Text

    private var personaStep3Title: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Analyze & tag"
        case .legal: return "Review & code"
        case .itAdmin: return "Inspect headers"
        case .journalist: return "Find patterns"
        case .personal, .general: return "Filter & explore"
        }
    }

    private var personaStep3Subtitle: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Tag evidence, verify integrity hashes, and build your audit trail"
        case .legal: return "Code documents for privilege, relevance, and responsiveness"
        case .itAdmin: return "Examine MIME structure, routing headers, and authentication results"
        case .journalist: return "Discover connections, timelines, and communication patterns"
        case .personal, .general: return "Filter by sender, recipient, date range, or reply frequency"
        }
    }

    private var personaStep4Icon: String {
        switch personaManager.selectedPersona {
        case .forensic: return "shield.checkered"
        case .legal: return "building.columns"
        case .itAdmin: return "terminal"
        case .journalist: return "sparkles"
        case .personal, .general: return "sparkles"
        }
    }

    private var personaStep4Title: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Export evidence"
        case .legal: return "Produce documents"
        case .itAdmin: return "Export & diagnose"
        case .journalist: return "Ask AI"
        case .personal, .general: return "Ask AI"
        }
    }

    private var personaStep4Subtitle: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Generate Bates-stamped PDFs, forensic reports, and Concordance load files"
        case .legal: return "Export Bates-numbered production sets, privilege logs, and redacted copies"
        case .itAdmin: return "Export CSV data, analyze routing, and identify authentication failures"
        case .journalist: return "Use AI to summarize threads, find contradictions, and build timelines"
        case .personal, .general: return "Use the AI assistant to summarize, analyze sentiment, or ask questions"
        }
    }

    private static let summaryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func formatted(_ date: Date) -> String {
        Self.summaryDateFormatter.string(from: date)
    }

    // MARK: - File Handling

    private func openPanelFallback() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mbox"),
            UTType(filenameExtension: "eml"),
            UTType(filenameExtension: "emlx"),
            UTType(filenameExtension: "msg"),
            UTType(filenameExtension: "pst"),
            UTType(filenameExtension: "ost"),
            UTType(filenameExtension: "nsf"),
            UTType(filenameExtension: "zip")
        ].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select email files (.mbox, .eml, .emlx, .msg, .pst, .ost, .nsf, .zip) from any email client"

        if panel.runModal() == .OK {
            parseFailed = false
            let urls = panel.urls
            let resolvedURLs = resolveZipFiles(urls)
            if resolvedURLs.count == 1, let url = resolvedURLs.first {
                resolveAndHandleSelectedFile(url)
            } else if resolvedURLs.count > 1 {
                handleMultipleFiles(resolvedURLs)
            }
        }
        #else
        showFileImporter = true
        #endif
    }

    private func resolveZipFiles(_ urls: [URL]) -> [URL] {
        var resolved: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                let extracted = viewModel.extractMailFilesFromZip(at: url)
                if extracted.isEmpty {
                    parseFailed = true
                } else {
                    resolved.append(contentsOf: extracted)
                }
            } else {
                resolved.append(url)
            }
        }
        return resolved
    }

private func handleMultipleFiles(_ urls: [URL]) {
        let supported = Set(ParserFactory.allSupportedExtensions)
        let validURLs = urls.filter { supported.contains($0.pathExtension.lowercased()) }
        guard !validURLs.isEmpty else {
            parseFailed = true
            return
        }
        showSpinner = true
        parseFailed = false
        let cap = storeManager.isPremium ? nil : StoreManager.freeEmailLimit
        viewModel.parseSelectedFiles(validURLs, removeDuplicates: removeDuplicates, maxEmails: cap)
    }

    private func resolveAndHandleSelectedFile(_ url: URL) {
        var resolvedURL: URL? = nil
        if url.hasDirectoryPath {
            let inner = url.appendingPathComponent("mbox")
            if FileUtils.fileExists(at: inner.path) {
                resolvedURL = inner
            }
        } else if ParserFactory.allSupportedExtensions.contains(url.pathExtension.lowercased()) {
            resolvedURL = url
        }
        if let fileToParse = resolvedURL {
            handleSelectedFile(fileToParse)
        } else {
            parseFailed = true
            showSpinner = false
        }
    }

    private func handleSelectedFile(_ url: URL) {
        showSpinner = true
        parseFailed = false
        let cap = storeManager.isPremium ? nil : StoreManager.freeEmailLimit
        viewModel.parseSelectedFiles([url], removeDuplicates: removeDuplicates, maxEmails: cap)
    }

    private static let freeExportLimit = 10

    // MARK: - Part O: streaming export plumbing

    /// Everything matching the current filters, as a SYMBOLIC scope — the
    /// export service streams it from the store; the bounded preview arrays
    /// are never the export source.
    /// Error surface for the unified sidebar export menu.
    @State private var sidebarExportError: String?

    private var filteredScope: ArchiveSelectionScope {
        .query(modelVM.currentArchiveQuery, exclusions: [])
    }

    /// O1: the bulk-action selection scope. Explicit checkbox selections stay
    /// a bounded id set; "Select All" (⌘A) is symbolic — the current query
    /// plus the (bounded) ids the user has since deselected in the visible
    /// page — so a bulk action over a million matches never materializes the
    /// id list.
    private var selectionScope: ArchiveSelectionScope {
        if selectAllMatching {
            let windowIDs = Set(modelVM.visibleOrderedIDs)
            let exclusions = windowIDs.subtracting(selectedEmailIDs)
            return .query(modelVM.currentArchiveQuery, exclusions: exclusions)
        }
        if !selectedEmailIDs.isEmpty { return .explicit(selectedEmailIDs) }
        return .none
    }

    /// Free-tier cap on export record counts (nil = unlimited for Pro).
    private var freeExportCap: Int? {
        storeManager.isPremium ? nil : Self.freeExportLimit
    }

    /// Shared runner: progress + Cancel via `ExportRunCenter`; cancellation and
    /// failure statuses are uniform (partial artifacts are cleaned by the
    /// service). `operation` returns the success status message.
    private func runStreamingExport(_ title: String,
                                    _ operation: @escaping @MainActor (ArchiveExportService) async throws -> String?) {
        let vm = viewModel
        ExportRunCenter.shared.run(title: title) {
            do {
                if let message = try await operation(ArchiveExportService.shared) {
                    vm.statusMessage = message
                    vm.statusColor = .green
                }
            } catch is CancellationError {
                vm.statusMessage = "\(title) cancelled — partial output removed."
                vm.statusColor = .orange
            } catch {
                vm.statusMessage = "\(title) failed: \(error.localizedDescription)"
                vm.statusColor = .red
            }
        }
    }

    /// Standard progress hook for the runner's overlay.
    private var exportProgress: @MainActor (Int, Int) -> Void {
        { done, total in ExportRunCenter.shared.update(done: done, total: total) }
    }

    /// Free-limit messaging shared by capped exports; returns the status
    /// message and raises the paywall when the cap truncated the export.
    private func cappedExportMessage(written: Int, scope: ArchiveSelectionScope,
                                     what: String) async -> String {
        if let cap = freeExportCap {
            let total = (try? await ArchiveDataService.shared.count(scope: scope)) ?? written
            if total > cap {
                storeManager.showPaywall = true
                return "Exported \(written) of \(total) \(what) (free limit). Upgrade for unlimited."
            }
        }
        return "Exported \(written) \(what)."
    }

    private static let exportCancelledSuffix = "cancelled — partial output removed."

    private func exportSelectedEmails() {
        let scope = selectionScope
        guard !scope.isEmpty else { return }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Export selected email(s)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let vm = viewModel
        let cap = freeExportCap
        runStreamingExport("Exporting selected emails as EML") { service in
            // Streams the (possibly symbolic) selection; one .eml per message.
            let result = try await service.exportEMLFiles(
                scope: scope, to: folderURL, limit: cap,
                render: { vm.exportEmailAsEML($0) },
                onProgress: self.exportProgress)
            if result.cancelled { return "EML export \(Self.exportCancelledSuffix)" }
            ForensicManager.shared.logAction("Export Selection", detail: "Exported \(result.recordsWritten) selected emails as EML")
            return await self.cappedExportMessage(written: result.recordsWritten, scope: scope, what: "selected emails")
        }
        #endif
    }

    private func exportSelectedAsIndividualPDFs() {
        let scope = selectionScope
        guard !scope.isEmpty else { return }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Export selected email(s) as individual PDFs"
        panel.prompt = "Export PDFs"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let cap = freeExportCap
        runStreamingExport("Exporting PDFs") { service in
            // Streams the selection; each PDF rendered per message (bounded).
            let result = try await service.exportPDFFiles(
                scope: scope, to: folderURL, limit: cap,
                onProgress: self.exportProgress)
            if result.cancelled { return "PDF export \(Self.exportCancelledSuffix)" }
            ForensicManager.shared.logAction("Individual PDF Export", detail: "\(result.recordsWritten) exported")
            return await self.cappedExportMessage(written: result.recordsWritten, scope: scope, what: "PDFs")
        }
        #endif
    }

    private func exportFilteredEmailsAsEML() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder to save .eml files"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        #else
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("eml_export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        #endif
        let scope = filteredScope
        let vm = viewModel
        let cap = freeExportCap
        runStreamingExport("Exporting emails as EML") { service in
            // Streams the whole filtered query from the store — never the
            // bounded preview arrays.
            let result = try await service.exportEMLFiles(
                scope: scope, to: folderURL, limit: cap,
                render: { vm.exportEmailAsEML($0) },
                onProgress: self.exportProgress)
            if result.cancelled { return "EML export \(Self.exportCancelledSuffix)" }
            #if os(iOS)
            if result.recordsWritten > 0 { self.iOSShareFile(at: folderURL) }
            #endif
            let message = await self.cappedExportMessage(written: result.recordsWritten, scope: scope, what: "emails")
            return message == "Exported \(result.recordsWritten) emails."
                ? "Exported \(result.recordsWritten) emails to \(folderURL.lastPathComponent)."
                : message
        }
    }

    private func exportFilteredEmailsAsCSV() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin_export_emails.csv"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_export_emails.csv")
        #endif
        let scope = filteredScope
        let cap = freeExportCap
        runStreamingExport("Exporting CSV") { service in
            // Streamed row-by-row from the store; incremental file writes.
            let result = try await service.exportDetailedCSV(
                scope: scope, to: url, limit: cap,
                onProgress: self.exportProgress)
            if result.cancelled { return "CSV export \(Self.exportCancelledSuffix)" }
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return await self.cappedExportMessage(written: result.recordsWritten, scope: scope, what: "emails as CSV")
        }
    }

    // MARK: - Forensic Exports
    private func exportBulkForensicCSV() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "forensic_export_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensic_export.csv")
        #endif
        let scope = filteredScope
        let forensic = forensicManager
        runStreamingExport("Exporting forensic CSV") { service in
            // Streamed + signed: Ed25519 over the incrementally computed SHA-256.
            let result = try await service.exportForensicCSV(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            if result.cancelled { return "Forensic CSV export \(Self.exportCancelledSuffix)" }
            forensic.logAction("Bulk Forensic Export", detail: "Exported \(result.recordsWritten) emails as forensic CSV to \(url.lastPathComponent) (signed, sha256 \(result.sha256Hex?.prefix(12) ?? ""))")
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported forensic CSV with \(result.recordsWritten) emails (signed)."
        }
    }

    private func exportConcordanceDAT() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "forensic_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).dat"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forensic_export.dat")
        #endif
        let scope = filteredScope
        let forensic = forensicManager
        runStreamingExport("Exporting Concordance load file") { service in
            let result = try await service.exportConcordanceDAT(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            if result.cancelled { return "Concordance export \(Self.exportCancelledSuffix)" }
            forensic.logAction("Concordance Export", detail: "Exported \(result.recordsWritten) emails as Concordance .dat (signed)")
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported Concordance load file with \(result.recordsWritten) records (signed)."
        }
    }

    private func exportTaggedOnly() {
        // Evidence tags are a bounded user-curated set — an explicit id scope.
        let taggedIDs = Set(forensicManager.evidenceTags.keys)
        guard !taggedIDs.isEmpty else {
            viewModel.statusMessage = "No tagged emails to export."
            viewModel.statusColor = .orange
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tagged_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tagged_export.csv")
        #endif
        let forensic = forensicManager
        runStreamingExport("Exporting tagged emails") { service in
            let result = try await service.exportForensicCSV(
                scope: .explicit(taggedIDs), to: url,
                onProgress: self.exportProgress)
            if result.cancelled { return "Tagged export \(Self.exportCancelledSuffix)" }
            forensic.logAction("Tagged Export", detail: "Exported \(result.recordsWritten) tagged emails (signed)")
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported \(result.recordsWritten) tagged emails (signed)."
        }
    }

    // MARK: - New Export Actions

    private func exportVCard() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "contacts.vcf"
        panel.allowedContentTypes = [.vCard]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contacts.vcf")
        #endif
        let scope = filteredScope
        runStreamingExport("Extracting contacts") { service in
            // Contacts are a small DERIVED record, but the source is the
            // streamed scope — not the preview arrays.
            let contactCount = try await service.exportVCard(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported \(contactCount) contacts as vCard."
        }
    }

    private func exportICS() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "events.ics"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("events.ics")
        #endif
        let scope = filteredScope
        runStreamingExport("Extracting calendar events") { service in
            // Events are extracted per streamed email and written incrementally.
            let events = try await service.exportICS(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            guard events > 0 else { return "ICS export \(Self.exportCancelledSuffix)" }
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported \(events) calendar events as ICS."
        }
    }

    private func exportHashManifest() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hash_manifest_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash_manifest.csv")
        #endif
        let scope = filteredScope
        let forensic = forensicManager
        runStreamingExport("Exporting hash manifest") { service in
            let result = try await service.exportHashManifest(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            if result.cancelled { return "Hash manifest export \(Self.exportCancelledSuffix)" }
            forensic.logAction("Hash Manifest Export", detail: "Exported hash manifest for \(result.recordsWritten) emails (signed)")
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported hash manifest for \(result.recordsWritten) emails (signed)."
        }
    }

    private func batchPrintFiltered() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "batch_print_emails.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch_print.txt")
        #endif
        let scope = filteredScope
        runStreamingExport("Building batch print file") { service in
            // Streamed continuous text — a million-message "print all" never
            // materializes; the file itself is the print artifact.
            let result = try await service.exportBatchPrintText(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            if result.cancelled { return "Batch print \(Self.exportCancelledSuffix)" }
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported batch print file with \(result.recordsWritten) emails."
        }
    }

    private func exportSelectedAsTIFF() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder to save TIFF images"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        #else
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("tiff_export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        #endif
        let scope = filteredScope
        runStreamingExport("Exporting TIFF images") { service in
            // Rendered per streamed message — bounded memory at any scale.
            let result = try await service.exportTIFFFiles(
                scope: scope, to: folderURL,
                onProgress: self.exportProgress)
            if result.cancelled { return "TIFF export \(Self.exportCancelledSuffix)" }
            #if os(iOS)
            if result.recordsWritten > 0 { self.iOSShareFile(at: folderURL) }
            #endif
            return "Exported \(result.recordsWritten) emails as TIFF images."
        }
    }

    private func exportPortableHTML() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder for the portable HTML export"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let baseURL = panel.url else { return }
        #else
        let baseURL = FileManager.default.temporaryDirectory
        #endif
        let folderURL = baseURL.appendingPathComponent("mailin_html_export")
        let scope = filteredScope
        let cap = freeExportCap
        runStreamingExport("Exporting portable HTML") { service in
            // Streamed into index.html. A single self-contained page must be
            // loaded whole by the browser, so the format carries an explicit
            // cap (ArchiveExportService.portableHTMLMaxEmails) — surfaced below.
            let result = try await service.exportPortableHTML(
                scope: scope, to: folderURL, limit: cap,
                onProgress: self.exportProgress)
            if result.cancelled { return "HTML export \(Self.exportCancelledSuffix)" }
            #if os(macOS)
            NSWorkspace.shared.selectFile(folderURL.appendingPathComponent("index.html").path, inFileViewerRootedAtPath: folderURL.path)
            #endif
            #if os(iOS)
            self.iOSShareFile(at: folderURL.appendingPathComponent("index.html"))
            #endif
            let total = (try? await ArchiveDataService.shared.count(scope: scope)) ?? result.recordsWritten
            if let cap, total > cap {
                self.storeManager.showPaywall = true
                return "Exported \(result.recordsWritten) of \(total) emails as portable HTML (free limit — upgrade for unlimited). Open index.html in any browser."
            }
            if total > ArchiveExportService.portableHTMLMaxEmails {
                return "Exported first \(result.recordsWritten) of \(total) emails as portable HTML (single-page format is capped at \(ArchiveExportService.portableHTMLMaxEmails) — use EML/CSV for the full set). Open index.html in any browser."
            }
            return "Exported \(result.recordsWritten) emails as portable HTML. Open index.html in any browser."
        }
    }

    private func exportReviewState() {
        guard let data = ExportManager.exportReviewState() else {
            viewModel.statusMessage = "No review state to export."
            viewModel.statusColor = .orange
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        let casePart = forensicManager.caseNumber.isEmpty ? "mailin" : forensicManager.caseNumber
        panel.nameFieldStringValue = "review_state_\(casePart).mailinreview"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review_state.mailinreview")
        #endif
        do {
            try data.write(to: url, options: .atomic)
            let sizeKB = data.count / 1024
            viewModel.statusMessage = "Exported review state (\(sizeKB) KB). Share this file with collaborators."
            viewModel.statusColor = .green
            forensicManager.logAction("Review State Exported", detail: "Exported to \(url.lastPathComponent)")
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export review state: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func importReviewState() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .data]
        panel.message = "Select a .mailinreview file from a collaborator"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try ExportManager.importReviewState(from: data, strategy: .merge)
            if result.total > 0 {
                viewModel.statusMessage = "Imported: \(result.summary)"
                viewModel.statusColor = .green
            } else {
                viewModel.statusMessage = "Review state imported — no new data (already up to date)."
                viewModel.statusColor = .blue
            }
        } catch {
            viewModel.statusMessage = "Failed to import review state: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
        #else
        showReviewImporter = true
        #endif
    }

    private func verifyAllEmailIntegrity() {
        let scope = filteredScope
        let vm = viewModel
        runStreamingExport("Verifying email integrity") { service in
            // Streamed verification — same math as batchVerifyAllEmails, but
            // over bounded batches from the store.
            let result = try await service.verifyIntegrity(
                scope: scope,
                onProgress: self.exportProgress)
            var message = "Integrity: \(result.passed) passed"
            if result.failed > 0 { message += ", \(result.failed) FAILED" }
            if result.unverified > 0 { message += ", \(result.unverified) unverified" }
            vm.statusMessage = message
            vm.statusColor = result.failed > 0 ? .red : .green
            return nil
        }
    }

    // MARK: - MSG/PST/Relativity Export

    private func exportMSG() {
        let scope = filteredScope
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export as MSG"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "msg_export"
        panel.prompt = "Export"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        runStreamingExport("Exporting MSG files") { service in
            // MSG is per-message OLE2 — streams unbounded (unlike PST).
            let result = try await service.exportMSGFiles(
                scope: scope, to: url,
                onProgress: self.exportProgress)
            if result.cancelled { return "MSG export \(Self.exportCancelledSuffix)" }
            return "Exported \(result.recordsWritten) MSG files."
        }
        #else
        let vm = viewModel
        ExportRunCenter.shared.run(title: "Exporting MSG") {
            // iOS shares a single .msg — hydrate just the first match.
            let first = try? await ArchiveDataService.shared
                .page(query: modelVM.currentArchiveQuery, cursor: nil, limit: 1).summaries.first
            guard let id = first?.id,
                  let email = try? await ArchiveDataService.shared.fullEmail(id: id),
                  let data = MSGWriter.write(email: email) else {
                vm.statusMessage = "MSG export failed."
                vm.statusColor = .red
                return
            }
            if let url = PlatformFileSaver.tempFileURL(name: "export.msg", data: data) {
                shareItems = [url]
                showShareSheet = true
            }
        }
        #endif
    }

    private func exportPST() {
        let scope = filteredScope
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export as PST"
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "export.pst"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        runStreamingExport("Exporting PST") { service in
            // KNOWN LIMITATION: the PST container writer builds the whole file
            // in memory, so this export materializes an EXPLICITLY CAPPED
            // array (ArchiveExportService.pstExportCap = PSTWriter's 5,000) —
            // never unbounded. The cap is surfaced to the user below; larger
            // sets should use the streaming EML/MSG exports.
            let collected = try await service.collectForPST(
                scope: scope,
                onProgress: self.exportProgress)
            let count = try PSTWriter.write(emails: collected.emails, to: url)
            if collected.capped {
                return "Exported first \(count) of \(collected.total) emails to PST (PST export is capped at \(ArchiveExportService.pstExportCap) messages — use EML or MSG for the full set)."
            }
            return "Exported \(count) emails to PST."
        }
        #else
        let vm = viewModel
        ExportRunCenter.shared.run(title: "Exporting PST") {
            do {
                // Same explicit cap as macOS (writer materializes in memory).
                let collected = try await ArchiveExportService.shared.collectForPST(scope: scope)
                let data = try PSTWriter.writeData(emails: collected.emails)
                if let url = PlatformFileSaver.tempFileURL(name: "export.pst", data: data) {
                    shareItems = [url]
                    showShareSheet = true
                }
                if collected.capped {
                    vm.statusMessage = "PST export capped at \(ArchiveExportService.pstExportCap) messages — use EML or MSG for the full set."
                    vm.statusColor = .orange
                }
            } catch {
                vm.statusMessage = "PST export failed: \(error.localizedDescription)"
                vm.statusColor = .red
            }
        }
        #endif
    }

    private func exportRelativity() {
        let scope = filteredScope
        let custodian = CustodianManager.shared.defaultCustodian
        let caseNumber = forensicManager.caseNumber
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Relativity Load File"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "relativity_loadfile.csv"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        runStreamingExport("Exporting Relativity load file") { service in
            let result = try await service.exportRelativityCSV(
                scope: scope, to: url,
                custodianName: custodian, caseNumber: caseNumber,
                onProgress: self.exportProgress)
            if result.cancelled { return "Relativity export \(Self.exportCancelledSuffix)" }
            return "Exported Relativity load file (\(result.recordsWritten) records, signed)."
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relativity_loadfile.csv")
        runStreamingExport("Exporting Relativity load file") { service in
            let result = try await service.exportRelativityCSV(
                scope: scope, to: url,
                custodianName: custodian, caseNumber: caseNumber,
                onProgress: self.exportProgress)
            if result.cancelled { return "Relativity export \(Self.exportCancelledSuffix)" }
            shareItems = [url]
            showShareSheet = true
            return "Exported Relativity load file (\(result.recordsWritten) records, signed)."
        }
        #endif
    }

    private func importFromCloud(_ emails: [MBOXParser.RawEmail]) {
        guard !emails.isEmpty else { return }
        // Part Q: cloud fetches are persisted into the SQLite authority + FTS
        // — no in-RAM corpus, no v1 JSON writes. `.parsingFinished` (posted by
        // ingestEmails) re-pages the list and refreshes derived caches.
        Task { @MainActor in
            await viewModel.ingestEmails(emails, sourceLabel: "cloud")
        }
    }

    // MARK: - State Change Handlers
    private func handleParseStateChange() {
        if modelVM.isParsed {
            modelVM.isPremiumUser = storeManager.isPremium
            modelVM.applyFilters()
            appState.hasParsedEmails = true
            appState.hasFilteredEmails = !modelVM.visibleEmails.isEmpty
        }
    }
    private func handlePremiumChange() {
        modelVM.isPremiumUser = storeManager.isPremium
        if storeManager.isPremium {
            UserDefaults.standard.removeObject(forKey: "freeAIQueryCount")
            UserDefaults.standard.removeObject(forKey: "freeAIFilterUsageCount")
            UserDefaults.standard.removeObject(forKey: "freeAttachmentDownloadCount")
        }
        if modelVM.isParsed {
            // Premium unlock lifts the free paging cap — re-page from the store.
            modelVM.refreshFromStore()
        }
    }
    private func handleFilteredChange() {
        appState.hasFilteredEmails = !modelVM.visibleEmails.isEmpty
        let validIDs = Set(modelVM.visibleOrderedIDs)
        let stale = selectedEmailIDs.subtracting(validIDs)
        if !stale.isEmpty { selectedEmailIDs.subtract(stale) }
        // O1: a symbolic Select All is tied to the query it was issued for —
        // any filter change invalidates it (the user re-selects if needed).
        selectAllMatching = false
    }

    // MARK: - Lifecycle Handlers
    private func handleAppear() {
        // First-run tour for new users — shown once, dismissable any time.
        // Gated on the launch flow being complete: if Terms or Persona
        // onboarding is still showing in the parent scene, presenting another
        // sheet here would race SwiftUI's "one sheet at a time" rule and the
        // tour would silently drop. Re-check on a slightly later tick.
        if UserDefaults.standard.bool(forKey: "hasSeenGettingStarted") == false {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350000000)
                tryShowGettingStartedWhenReady(attempt: 0)
            }
        }
        // (helper defined below: tryShowGettingStartedWhenReady)

        parsingObserver = NotificationCenter.default.addObserver(
            forName: .parsingFinished, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selectedEmailIDs.removeAll()
                modelVM.invalidateSearchCache()
                modelVM.resetFilters()
                // Part Q: NO v1 JSON writes and NO in-RAM precompute over a
                // preview array — the list re-pages the SQLite authority and
                // derived state is persisted (Parts I–M) / computed lazily.
                modelVM.refreshFromStore()
                showSpinner = false
                SpotlightIndexer.shared.indexAllFromArchive()   // bounded: streams from SQLite, no corpus
                #if canImport(FoundationModels)
                if #available(macOS 26, iOS 26, *) {
                    FoundationModelEngine.invalidateProfileCache()
                    FoundationModelEngine.invalidateAnswerCache()
                }
                #endif
                AIAssistantView.invalidateNLPCache()
                AIAssistantView.invalidateNLPPrecomputation()

                // Record successful import and prompt for review if appropriate
                if viewModel.totalParsedCount > 0 {
                    ReviewPromptManager.recordImport()
                }
            }
        }
        if autoDetectSender && viewModel.senderEmail.isEmpty && !defaultSenderEmail.isEmpty {
            viewModel.senderEmail = defaultSenderEmail
        }
        // Part Q: NO startup corpus rehydration. Storage is activated in
        // mailinApp; here we only refresh the store-backed archive count and
        // let the paged list load its first summaries page. Nothing is
        // reconstructed in RAM at launch.
        Task { @MainActor in
            let total = (try? await ArchiveDataService.shared.count()) ?? 0
            guard total > 0 else { return }
            viewModel.totalParsedCount = total
            viewModel.isParsed = true
            modelVM.refreshFromStore()
        }

        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500000000)
            if WhatsNewView.shouldShow() {
                appState.showWhatsNew = true
            }
        }
    }

    private func handleDisappear() {
        if let observer = parsingObserver {
            NotificationCenter.default.removeObserver(observer)
            parsingObserver = nil
        }
    }

    /// Attempt to present the Getting Started tour once the launch flow has
    /// stopped occupying the root sheet slot. The terms-acceptance and
    /// persona-onboarding sheets attach in `mailinApp.swift`; while either
    /// is up, presenting another sheet here would trigger SwiftUI's
    /// "Currently, only presenting a single sheet is supported" fault and
    /// the tour would silently drop. We poll at 0.4 s intervals up to ~6 s,
    /// then give up — the tour will surface on the next launch instead.
    private func tryShowGettingStartedWhenReady(attempt: Int) {
        guard attempt < 15 else { return }
        let termsBlocking = LegalComplianceManager.shared.needsTermsAcceptance
        let personaBlocking = !PersonaManager.shared.hasCompletedPersonaSelection
        guard !termsBlocking, !personaBlocking else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400000000)
                tryShowGettingStartedWhenReady(attempt: attempt + 1)
            }
            return
        }
        showGettingStarted = true
    }

    /// Part G6: clearing data is a STORE-level deletion that respects legal
    /// hold — not a rewrite of the resident preview arrays. Non-held emails
    /// are deleted from the SQLite authority + FTS in bounded keyset batches
    /// (the same guarded FTS-first path `removeEmails` uses); held emails are
    /// re-hydrated by id as the surviving preview. A failed store delete
    /// leaves the UI untouched and surfaces the error (no optimistic clear).
    private func handleDataCleared() {
        selectedEmailIDs.removeAll()
        modelVM.resetFilters()

        Task { @MainActor in
            // §11: ONE canonical clear — SQLite rows (respecting legal holds),
            // FTS, per-email forensic state, Spotlight, import checkpoints,
            // legacy JSON + SwiftData stores, and the no-resurrection
            // tombstone. Throws on storage failure: the archive is NOT
            // presented as empty when it is not.
            let outcome: ArchiveLifecycleService.ClearOutcome
            do {
                outcome = try await ArchiveLifecycleService.shared.clearArchive()
            } catch {
                viewModel.statusMessage = "Clear failed: \(error.localizedDescription). Your emails were not removed."
                viewModel.statusColor = .red
                return
            }
            for warning in outcome.warnings {
                viewModel.statusMessage = warning
                viewModel.statusColor = .orange
            }

            viewModel.clearParsedData()
            if outcome.heldKept > 0 {
                viewModel.totalParsedCount = outcome.heldKept
                viewModel.isParsed = true
            }
            modelVM.invalidateSearchCache()
            modelVM.refreshFromStore()

            EmailSearchIndex.shared.clear()
            EmailSearchIndex.shared.deleteDiskCache()
            AIAssistantView.invalidateNLPCache()
            AIAssistantView.invalidateNLPPrecomputation()
            appState.hasParsedEmails = outcome.heldKept > 0
            appState.hasFilteredEmails = outcome.heldKept > 0
        }
    }

    // MARK: - Menu Trigger Handlers
    private func handleTriggerSearch() {
        guard appState.triggerSearch else { return }
        appState.triggerSearch = false
        modelVM.isSearchFocused = true
    }
    private func handleTriggerSelectAll() {
        guard appState.triggerSelectAll else { return }
        appState.triggerSelectAll = false
        // O1: the list UI shows the (page-bounded) preview as checked, but the
        // SELECTION ITSELF turns symbolic — bulk actions consume
        // `selectionScope` = current query + deselected ids, so "Select All"
        // over a million matches never materializes the id list.
        selectedEmailIDs = Set(modelVM.visibleOrderedIDs)
        selectAllMatching = true
    }
    private func handleTriggerPrint() {
        guard appState.triggerPrint else { return }
        appState.triggerPrint = false
        NotificationCenter.default.post(name: .printCurrentEmail, object: nil)
    }
    private func handleTriggerNewImport() {
        guard appState.triggerNewImport else { return }
        appState.triggerNewImport = false
        showNewImportConfirmation = true
    }

    private func exportAuditLog() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "audit_log_\(forensicManager.caseNumber.isEmpty ? "mailin" : forensicManager.caseNumber).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit_log.txt")
        #endif
        Task { @MainActor in
            do {
                let total = try await forensicManager.exportAuditLogStreamed(to: url)
                viewModel.statusMessage = "Exported audit log with \(total) entries."
                viewModel.statusColor = .green
                #if os(iOS)
                iOSShareFile(at: url)
                #endif
            } catch {
                viewModel.statusMessage = "Failed to export audit log: \(error.localizedDescription)"
                viewModel.statusColor = .red
            }
        }
    }

    private func exportPrivilegeLog() {
        // Part O: privileged messages are a bounded user-tagged set — hydrate
        // just those ids from the store (never the whole-corpus array).
        let privilegedIDs = forensicManager.evidenceTags
            .filter { $0.value == .privileged }.map(\.key)
        guard !privilegedIDs.isEmpty else {
            viewModel.statusMessage = "No privileged emails to export."
            viewModel.statusColor = .orange
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "privilege_log_\(forensicManager.caseNumber.isEmpty ? "mailin" : forensicManager.caseNumber).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("privilege_log.txt")
        #endif
        let forensic = forensicManager
        runStreamingExport("Exporting privilege log") { _ in
            let emails = try await ArchiveDataService.shared.fullEmails(ids: privilegedIDs)
            let content = forensic.exportPrivilegeLog(emails: emails)
            try content.write(to: url, atomically: true, encoding: .utf8)
            #if os(iOS)
            self.iOSShareFile(at: url)
            #endif
            return "Exported privilege log."
        }
    }

    // MARK: - iOS Share Helper
    #if os(iOS)
    private func iOSShareFile(at url: URL) {
        shareItems = [url]
        showShareSheet = true
    }
    #endif

    // MARK: - Collaboration Banner

    private var collaborationBanner: some View {
        let count = collabManager.newImportCount
        let newest = collabManager.availableImports.first(where: \.isNew)
        return HStack(spacing: Spacing.xSmall) {
            Image(systemName: "person.2.fill")
                .foregroundColor(.white)
                .font(.footnote)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) new review update\(count == 1 ? "" : "s")")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                if let reviewer = newest {
                    Text("From \(reviewer.examiner) \(reviewer.age)")
                        .font(Typography.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            Button {
                if let file = newest {
                    do {
                        let result = try collabManager.importFile(file)
                        viewModel.statusMessage = "Imported from \(file.examiner): \(result.summary)"
                        viewModel.statusColor = .green
                    } catch {
                        viewModel.statusMessage = "Import failed: \(error.localizedDescription)"
                        viewModel.statusColor = .red
                    }
                }
            } label: {
                Text("Import")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 3)
                    .background(.white)
                    .cornerRadius(CornerRadius.small)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xSmall)
        .background(Color.blue.opacity(0.9))
        .cornerRadius(CornerRadius.medium)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

}

// MARK: - Advanced Feature Sheets Modifier
struct MenuTriggerModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    var onFileImport: () -> Void
    var onExport: () -> Void
    var onAuditLog: () -> Void
    var onForensicCSV: () -> Void
    var onSearch: () -> Void
    var onSelectAll: () -> Void
    var onPrint: () -> Void
    var onNewImport: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.triggerFileImport) {
                if appState.triggerFileImport { appState.triggerFileImport = false; onFileImport() }
            }
            .onChange(of: appState.triggerExport) {
                if appState.triggerExport { appState.triggerExport = false; onExport() }
            }
            .onChange(of: appState.showReplyStats) {
                if appState.showReplyStats { appState.showReplyStats = false; appState.showReplyStatsSheet = true }
            }
            .onChange(of: appState.triggerAuditLogExport) {
                if appState.triggerAuditLogExport { appState.triggerAuditLogExport = false; onAuditLog() }
            }
            .onChange(of: appState.triggerForensicCSVExport) {
                if appState.triggerForensicCSVExport { appState.triggerForensicCSVExport = false; onForensicCSV() }
            }
            .onChange(of: appState.triggerSearch) { onSearch() }
            .onChange(of: appState.triggerSelectAll) { onSelectAll() }
            .onChange(of: appState.triggerPrint) { onPrint() }
            .onChange(of: appState.triggerNewImport) { onNewImport() }
    }
}

struct AdvancedFeatureSheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    @ObservedObject var predictiveEngine: PredictiveCodingEngine
    @ObservedObject var custodianManager: CustodianManager
    @ObservedObject var reviewBatchManager: ReviewBatchManager
    @Binding var selectedClusterFilter: String?
    @Binding var selectedEmailIDs: Set<UUID>
    var exportVCard: () -> Void
    var exportICS: () -> Void
    var exportHashManifest: () -> Void
    var batchPrintFiltered: () -> Void
    var verifyAllEmailIntegrity: () -> Void
    var exportMSG: () -> Void
    var exportPST: () -> Void
    var exportRelativity: () -> Void
    var importFromCloud: ([MBOXParser.RawEmail]) -> Void
    var senderEmail: String

    /// Part G1: sheets that still take `[RawEmail]` are hosted over a bounded
    /// working set streamed from the store for the CURRENT query — never the
    /// resident preview arrays.
    private var currentQuery: EmailQuery { modelVM.currentArchiveQuery }

    func body(content: Content) -> some View {
        content
            // Part O: shared progress + Cancel for streaming exports.
            .overlay(alignment: .bottom) { ExportProgressOverlayView() }
            .sheet(isPresented: $appState.showDuplicateManager) {
                DuplicateManagerView(model: modelVM, isPresented: $appState.showDuplicateManager)
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 340)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showPredictiveCoding) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    PredictiveCodingView(emails: emails, engine: predictiveEngine, isPresented: $appState.showPredictiveCoding)
                }
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showCustodianPanel) {
                CustodianPanelView(manager: custodianManager, isPresented: $appState.showCustodianPanel)
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 340)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showReviewBatches) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    ReviewBatchPanelView(emails: emails, manager: reviewBatchManager, isPresented: $appState.showReviewBatches)
                }
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 340)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .onChange(of: appState.triggerExportVCard) { _, val in
                if val { appState.triggerExportVCard = false; exportVCard() }
            }
            .onChange(of: appState.triggerExportICS) { _, val in
                if val { appState.triggerExportICS = false; exportICS() }
            }
            .onChange(of: appState.triggerExportHashManifest) { _, val in
                if val { appState.triggerExportHashManifest = false; exportHashManifest() }
            }
            .onChange(of: appState.triggerExportHeadersCSV) { _, val in
                if val {
                    appState.triggerExportHeadersCSV = false
                    // Part O: streamed from the store for the current query —
                    // never the preview arrays.
                    #if os(macOS)
                    if let url = PlatformFileSaver.savePanel(suggestedName: "headers_export.csv") {
                        let scope: ArchiveSelectionScope = .query(modelVM.currentArchiveQuery, exclusions: [])
                        ExportRunCenter.shared.run(title: "Exporting headers CSV") {
                            _ = try? await ArchiveExportService.shared.exportHeadersCSV(
                                scope: scope, to: url,
                                onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
                        }
                    }
                    #endif
                }
            }
            .onChange(of: appState.triggerBatchPrint) { _, val in
                if val { appState.triggerBatchPrint = false; batchPrintFiltered() }
            }
            .onChange(of: appState.triggerVerifyIntegrity) { _, val in
                if val { appState.triggerVerifyIntegrity = false; verifyAllEmailIntegrity() }
            }
            .onChange(of: appState.triggerExportMSG) { _, val in
                if val { appState.triggerExportMSG = false; exportMSG() }
            }
            .onChange(of: appState.triggerExportPST) { _, val in
                if val { appState.triggerExportPST = false; exportPST() }
            }
            .onChange(of: appState.triggerExportRelativity) { _, val in
                if val { appState.triggerExportRelativity = false; exportRelativity() }
            }
            .sheet(isPresented: $appState.showAttachmentGrid) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    AttachmentGridView(emails: emails)
                }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 360)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showTimeline) {
                // nil emails → the timeline streams the archive from the store.
                EmailTimelineView(isPresented: $appState.showTimeline)
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showRelationshipGraph) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    RelationshipGraphView(emails: emails, senderEmail: senderEmail, isPresented: $appState.showRelationshipGraph)
                }
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showArchiveComparison) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    ArchiveComparisonSheetWrapper(archiveA: emails)
                }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 360)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showInvestigationReport) {
                ArchiveWorkingSetView(query: currentQuery) { emails in
                    InvestigationReportConfigSheet(emails: emails, senderEmail: senderEmail, isPresented: $appState.showInvestigationReport)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #endif
            }
            .modifier(V7SheetsModifier(appState: appState, query: currentQuery, senderEmail: senderEmail, selectedEmailIDs: $selectedEmailIDs, modelVM: modelVM))
    }
}

// MARK: - V7 Sheets Modifier
struct V7SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    /// Part G1: the current archive query; each sheet streams its own bounded
    /// working set — no preview array is passed down.
    var query: EmailQuery
    var senderEmail: String
    @Binding var selectedEmailIDs: Set<UUID>
    @ObservedObject var modelVM: ParsedEmailListViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showAutomationRules) {
                ArchiveWorkingSetView(query: query) { emails in
                    AutomationRulesView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }
            .sheet(isPresented: $appState.showBatchOperations) {
                ArchiveWorkingSetView(query: query) { emails in
                    BatchOperationsView(
                        emails: emails,
                        selectedIDs: $selectedEmailIDs,
                        onTagApplied: { tag, ids in
                            let idArray = Array(ids)
                            if tag.isEmpty {
                                modelVM.review.clearAllTags(for: idArray)
                            } else {
                                modelVM.review.addTag(tag, to: idArray)
                            }
                        },
                        onExportRequested: { emailsToExport, format in
                            appState.triggerExport = true
                        },
                        isPresented: $appState.showBatchOperations
                    )
                }
                .resizableSheet()
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
            }
            .sheet(isPresented: $appState.showThreadSummarizer) {
                ArchiveWorkingSetView(query: query) { emails in
                    ThreadSummarizerView(threadEmails: emails, isPresented: $appState.showThreadSummarizer)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }
            .sheet(isPresented: $appState.showSmartAlerts) {
                ArchiveWorkingSetView(query: query) { emails in
                    SmartAlertsView(emails: emails, isPresented: $appState.showSmartAlerts)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 350)
                    #endif
            }
            .modifier(V7ForensicSheetsModifier(appState: appState, query: query))
    }
}

struct V7ForensicSheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    var query: EmailQuery

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showEDiscovery) {
                ArchiveWorkingSetView(query: query) { emails in
                    EDiscoveryWorkflowView(emails: emails, isPresented: $appState.showEDiscovery)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 380)
                    #endif
            }
            .sheet(isPresented: $appState.showBatesNumbering) {
                ArchiveWorkingSetView(query: query) { emails in
                    BatesConfigView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }
            .sheet(isPresented: $appState.showRedaction) {
                ArchiveWorkingSetView(query: query) { emails in
                    RedactionConfigView(emails: emails)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }
            .sheet(isPresented: $appState.showGDPRReport) {
                ArchiveWorkingSetView(query: query) { emails in
                    GDPRReportConfigView(emails: emails, isPresented: $appState.showGDPRReport)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }
            .sheet(isPresented: $appState.showChainOfCustody) {
                ArchiveWorkingSetView(query: query) { emails in
                    ChainOfCustodyView(emails: emails, isPresented: $appState.showChainOfCustody)
                }
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                    #endif
            }
    }
}

// MARK: - V8 Sheets Modifier (Intelligence & Polish)
struct V8SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showNearDuplicates) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    NearDuplicateDetectionView(emails: emails, isPresented: $appState.showNearDuplicates)
                }
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showAnomalyDetection) {
                AnomalyDetectionView(isPresented: $appState.showAnomalyDetection)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showSmartAutoTagger) {
                SmartAutoTaggerView(isPresented: $appState.showSmartAutoTagger)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showAIDigest) {
                // Zero-array digest: the generator streams a bounded working
                // set of the selected period from the store itself.
                AIDigestView(isPresented: $appState.showAIDigest)
                    .resizableSheet()
            }
    }
}

// MARK: - V9 Sheets Modifier (Dashboard, Security & Workspaces)
struct V9SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    var senderEmail: String

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showExecutiveDashboard) {
                // Query injection: the dashboard streams the current scope
                // from SQLite in bounded pages (no array plumbing).
                ExecutiveDashboardView(query: modelVM.currentArchiveQuery, isPresented: $appState.showExecutiveDashboard)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showReportBuilder) {
                ReportBuilderView(isPresented: $appState.showReportBuilder)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showKeywordMonitor) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    KeywordMonitorView(emails: emails, isPresented: $appState.showKeywordMonitor)
                }
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showCommunicationPatterns) {
                CommunicationPatternsView(senderEmail: senderEmail, isPresented: $appState.showCommunicationPatterns)
                    .resizableSheet()
            }
            .modifier(V9UtilitySheetsModifier(appState: appState, modelVM: modelVM))
    }
}

struct V9UtilitySheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    @EnvironmentObject private var storeManager: StoreManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showWorkspaceManager) {
                WorkspaceManagerView(isPresented: $appState.showWorkspaceManager)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showCommandPalette) {
                CommandPaletteView { command in
                    appState.showCommandPalette = false
                    handleCommand(command)
                }
                .resizableSheet()
            }
            .sheet(isPresented: $appState.showKeyboardShortcuts) {
                KeyboardShortcutOverlayView()
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showWhatsNew) {
                WhatsNewView()
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showAllAttachmentsGallery) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    AllAttachmentsGalleryView(emails: emails)
                }
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showIOCExtractor) {
                ArchiveWorkingSetView(query: modelVM.currentArchiveQuery) { emails in
                    IOCExtractorView(emails: emails)
                }
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showGuidedSearch) {
                GuidedSearchView(searchText: $modelVM.searchText, isPresented: $appState.showGuidedSearch, onSearch: {
                    modelVM.searchTextDidChange()
                })
                    .resizableSheet()
            }
    }

    private func handleCommand(_ id: String) {
        switch id {
        case "askAI":
            if storeManager.requirePremium() { appState.showAIAssistant = true }
        case "analytics":
            if storeManager.requirePremium() { appState.showAnalytics = true }
        case "topicClusters":
            if storeManager.requirePremium() { withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics } }
        case "duplicates":
            if storeManager.requirePremium() { appState.showDuplicateManager = true }
        case "predictiveCoding":
            if storeManager.requireProfessional() { appState.showPredictiveCoding = true }
        case "timeline":
            if storeManager.requirePremium() { appState.showTimeline = true }
        case "relationshipGraph":
            if storeManager.requirePremium() { appState.showRelationshipGraph = true }
        case "smartAlerts":
            if storeManager.requirePremium() { appState.showSmartAlerts = true }
        case "anomalyDetection":
            if storeManager.requirePremium() { appState.showAnomalyDetection = true }
        case "autoTagger":
            if storeManager.requirePremium() { appState.showSmartAutoTagger = true }
        case "emailDigest":
            if storeManager.requirePremium() { appState.showAIDigest = true }
        case "nearDuplicates":
            if storeManager.requirePremium() { appState.showNearDuplicates = true }
        case "commPatterns":
            if storeManager.requirePremium() { appState.showCommunicationPatterns = true }
        case "dashboard":
            if storeManager.requirePremium() { appState.showExecutiveDashboard = true }
        case "keywordMonitor":
            if storeManager.requirePremium() { appState.showKeywordMonitor = true }
        case "reportBuilder":
            if storeManager.requirePremium() { appState.showReportBuilder = true }
        case "eDiscovery":
            if storeManager.requireProfessional() { appState.showEDiscovery = true }
        case "batesNumbering":
            if storeManager.requireProfessional() { appState.showBatesNumbering = true }
        case "redaction":
            if storeManager.requireProfessional() { appState.showRedaction = true }
        case "gdprReport":
            if storeManager.requireProfessional() { appState.showGDPRReport = true }
        case "chainOfCustody":
            if storeManager.requireProfessional() { appState.showChainOfCustody = true }
        case "forensicMode":
            ForensicManager.shared.isEnabled.toggle()
        case "custodianManager":
            if storeManager.requireProfessional() { appState.showCustodianPanel = true }
        case "reviewBatches":
            if storeManager.requireProfessional() { appState.showReviewBatches = true }
        case "investigationReport":
            if storeManager.requireProfessional() { appState.showInvestigationReport = true }
        case "exportFiltered":
            appState.triggerExport = true
        case "exportVCard":
            appState.triggerExportVCard = true
        case "exportICS":
            appState.triggerExportICS = true
        case "exportMSG":
            appState.triggerExportMSG = true
        case "exportPST":
            appState.triggerExportPST = true
        case "exportRelativity":
            appState.triggerExportRelativity = true
        case "workspaces": appState.showWorkspaceManager = true
        case "toggleSidebar": appState.toggleSidebar()
        case "allAttachments": appState.showAllAttachmentsGallery = true
        case "iocExtractor":
            if storeManager.requireProfessional() { appState.showIOCExtractor = true }
        case "guidedSearch": appState.showGuidedSearch = true
        default: break
        }
    }
}

// MARK: - Archive Comparison Sheet Wrapper
struct ArchiveComparisonSheetWrapper: View {
    let archiveA: [MBOXParser.RawEmail]
    @State private var archiveB: [MBOXParser.RawEmail] = []
    @State private var showFilePicker = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var hasImported = false
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if hasImported && !archiveB.isEmpty {
            ArchiveComparisonView(
                archiveA: archiveA,
                archiveB: archiveB,
                nameA: "Current Archive",
                nameB: "Imported Archive"
            )
        } else {
            VStack(spacing: Spacing.large) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.largeTitle)
                    .foregroundColor(AppColors.primary)

                Text("Archive Comparison")
                    .font(Typography.title2)

                Text("Compare your current archive (\(archiveA.count) emails) with a second archive. Import a second .mbox file to compare.")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                if isImporting {
                    ProgressView("Importing second archive...")
                } else if let error = importError {
                    Text(error)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.error)
                }

                HStack(spacing: Spacing.medium) {
                    Button("Import Second Archive...") {
                        showFilePicker = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isImporting)

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(Spacing.xLarge)
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 300)
            #endif
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "mbox"),
                    UTType(filenameExtension: "eml"),
                    UTType(filenameExtension: "emlx"),
                    UTType(filenameExtension: "msg"),
                    UTType(filenameExtension: "pst"),
                    UTType(filenameExtension: "ost"),
                    UTType(filenameExtension: "nsf")
                ].compactMap { $0 },
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importSecondArchive(url: url)
                case .failure(let error):
                    importError = "Failed to select file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func importSecondArchive(url: URL) {
        isImporting = true
        importError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        let sender = defaultSenderEmail
        Task.detached(priority: .userInitiated) {
            do {
                let emails = try MBOXParser.parse(fileURL: url, senderEmail: sender)
                await MainActor.run {
                    archiveB = emails
                    hasImported = true
                    isImporting = false
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            } catch {
                await MainActor.run {
                    importError = "Failed to parse file: \(error.localizedDescription)"
                    isImporting = false
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }
}

// MARK: - Investigation Report Configuration Sheet
struct InvestigationReportConfigSheet: View {
    let emails: [MBOXParser.RawEmail]
    let senderEmail: String
    var isPresented: Binding<Bool>?
    @ObservedObject private var forensicManager = ForensicManager.shared
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) private var envDismiss

    @State private var examinerName: String = ""
    @State private var reportTitle: String = "Email Investigation Report"
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var selectedEmailIDs: Set<UUID> = []
    @State private var showEmailSelector = false
    @State private var emailSearchText = ""
    @State private var generatedPDFData: Data?
    @State private var showFileExporter = false
    @State private var savedSuccessfully = false

    private var matchingEmails: [MBOXParser.RawEmail] {
        guard !emailSearchText.isEmpty else { return emails }
        let query = emailSearchText.lowercased()
        return emails.filter {
            ($0.headers["From"] ?? "").lowercased().contains(query) ||
            ($0.headers["Subject"] ?? "").lowercased().contains(query) ||
            ($0.headers["To"] ?? "").lowercased().contains(query)
        }
    }

    private var selectedEmails: [MBOXParser.RawEmail] {
        emails.filter { selectedEmailIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(AppColors.primary)
                Text("Generate Investigation Report")
                    .font(Typography.headline)
                Spacer()
                Button { closeSheet() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Text("Report Configuration")
                            .font(Typography.callout)
                            .fontWeight(.semibold)

                        TextField("Report Title", text: $reportTitle)
                            .textFieldStyle(.roundedBorder)
                        TextField("Investigator / Examiner Name", text: $examinerName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Email Selection
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        HStack {
                            Text("Email Selection")
                                .font(Typography.callout)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(selectedEmailIDs.count) of \(emails.count) selected")
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                        }

                        HStack(spacing: Spacing.small) {
                            Button("Select All") {
                                selectedEmailIDs = Set(emails.map(\.id))
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                            .disabled(selectedEmailIDs.count == emails.count)

                            Button("Deselect All") {
                                selectedEmailIDs.removeAll()
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                            .disabled(selectedEmailIDs.isEmpty)

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showEmailSelector.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(showEmailSelector ? "Hide Emails" : "Choose Emails")
                                        .font(Typography.caption1)
                                    Image(systemName: showEmailSelector ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9))
                                }
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                        }

                        if showEmailSelector {
                            VStack(spacing: Spacing.xSmall) {
                                TextField("Search emails...", text: $emailSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Typography.caption1)

                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(matchingEmails, id: \.id) { email in
                                            emailSelectionRow(email)
                                        }
                                    }
                                }
                                .frame(maxHeight: 200)
                                .background(AppColors.backgroundSecondary)
                                .cornerRadius(CornerRadius.small)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        Text("Report Contents")
                            .font(Typography.callout)
                            .fontWeight(.semibold)

                        Group {
                            Label("Title page with case info", systemImage: "doc.text")
                            Label("Executive summary with NLP analysis", systemImage: "text.magnifyingglass")
                            Label("Email timeline (monthly volume chart)", systemImage: "chart.bar")
                            Label("Top contacts table", systemImage: "person.2")
                            Label("Category breakdown", systemImage: "folder")
                            Label("Evidence tags summary", systemImage: "tag")
                            Label("Flagged / important emails", systemImage: "flag")
                        }
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    }

                    Divider()

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(AppColors.info)
                        Text("Report will analyze \(selectedEmailIDs.count) email\(selectedEmailIDs.count == 1 ? "" : "s") and generate a multi-page PDF.")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }

                    if let error = generationError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AppColors.error)
                            Text(error)
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.error)
                        }
                    }

                    if savedSuccessfully {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Report saved successfully.")
                                .font(Typography.caption1)
                                .foregroundColor(.green)
                        }
                    } else if generatedPDFData != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Report generated. Click Save PDF to save.")
                                .font(Typography.caption1)
                                .foregroundColor(.green)
                        }
                    }

                    HStack {
                        Spacer()
                        if savedSuccessfully {
                            Button("Done") { closeSheet() }
                                .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button("Cancel") { closeSheet() }
                                .buttonStyle(SecondaryButtonStyle())

                            if generatedPDFData != nil {
                                Button {
                                    showFileExporter = true
                                } label: {
                                    HStack(spacing: Spacing.xSmall) {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("Save PDF")
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            } else {
                                Button {
                                    generateReport()
                                } label: {
                                    HStack(spacing: Spacing.xSmall) {
                                        if isGenerating {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .frame(width: 16, height: 16)
                                        }
                                        Text(isGenerating ? "Generating..." : "Generate PDF Report")
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(isGenerating || selectedEmailIDs.isEmpty)
                            }
                        }
                    }
                }
                .padding(Spacing.medium)
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: InvestigationPDFExportFile(data: generatedPDFData),
            contentType: .pdf,
            defaultFilename: pdfFileName
        ) { result in
            switch result {
            case .success:
                forensicManager.logAction("Investigation Report", detail: "Generated PDF report for \(selectedEmailIDs.count) emails")
                generatedPDFData = nil
                savedSuccessfully = true
            case .failure(let error):
                generationError = "Failed to save: \(error.localizedDescription)"
            }
        }
        .onAppear {
            selectedEmailIDs = Set(emails.map(\.id))
            examinerName = forensicManager.examinerName
            if !forensicManager.caseNumber.isEmpty {
                reportTitle = "Case \(forensicManager.caseNumber) — Investigation Report"
            }
        }
    }

    private func closeSheet() {
        if let isPresented { isPresented.wrappedValue = false } else { envDismiss() }
    }

    private var pdfFileName: String {
        let safeName = reportTitle.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        return safeName
    }

    private func emailSelectionRow(_ email: MBOXParser.RawEmail) -> some View {
        let isSelected = selectedEmailIDs.contains(email.id)
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let subject = email.headers["Subject"] ?? "(No Subject)"

        return Button {
            if isSelected {
                selectedEmailIDs.remove(email.id)
            } else {
                selectedEmailIDs.insert(email.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? AppColors.primary : AppColors.secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(from)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(subject)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(email.headers["Date"]?.prefix(16) ?? "")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func generateReport() {
        isGenerating = true
        generationError = nil

        let reportEmails = selectedEmails
        let title = reportTitle
        let investigator = examinerName

        Task.detached(priority: .userInitiated) {
            let pdfData = await InvestigationReportGenerator.generateReport(
                emails: reportEmails,
                title: title,
                investigatorName: investigator
            )

            await MainActor.run {
                isGenerating = false
                guard !pdfData.isEmpty else {
                    generationError = "Failed to generate PDF report."
                    return
                }
                generatedPDFData = pdfData
            }
        }
    }
}

struct InvestigationPDFExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init?(data: Data?) {
        guard let data, !data.isEmpty else { return nil }
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Email Management Modifier

struct EmailManagementModifier: ViewModifier {
    @ObservedObject var modelVM: ParsedEmailListViewModel
    @Binding var selectedEmailIDs: Set<UUID>

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deleteCurrentEmail)) { notification in
                if let emailID = notification.object as? UUID {
                    modelVM.deleteEmail(emailID)
                    selectedEmailIDs.remove(emailID)
                    modelVM.applyFilters()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .archiveCurrentEmail)) { notification in
                if let emailID = notification.object as? UUID {
                    modelVM.archiveEmail(emailID)
                    selectedEmailIDs.remove(emailID)
                    modelVM.applyFilters()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadCurrentEmail)) { notification in
                if let emailID = notification.object as? UUID {
                    modelVM.toggleRead(emailID)
                }
            }
    }
}

// MARK: - InfoBanner
struct InfoBanner: View {
    var text: String
    var color: Color = AppColors.primary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundColor(.white)
            }
            Text(text)
                .font(Typography.callout)
                .foregroundColor(.white)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
        .background(color.opacity(0.95))
        .cornerRadius(CornerRadius.medium)
        .shadow(color: .black.opacity(0.08), radius: Shadows.medium.radius, y: Shadows.medium.y)
        .padding(.horizontal, Spacing.medium)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(AnimationTiming.normal, value: text)
    }
}

// MARK: - VisualEffectBlur for Modern Blur Background
#if os(macOS)
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .windowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}
#else
struct VisualEffectBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let blur = UIBlurEffect(style: .systemMaterial)
        return UIVisualEffectView(effect: blur)
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) { }
}
#endif

// MARK: - Sidebar Section Header
struct SidebarSectionHeader: View {
    let title: String
    let icon: String
    var color: Color = AppColors.primary
    var helpText: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(color.opacity(0.8))
                .tracking(0.5)
            if let helpText {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundColor(AppColors.secondary.opacity(0.5))
                    .help(helpText)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
    }
}

// MARK: - Feature Badge
struct FeatureBadge: View {
    let icon: String
    let text: String
    var color: Color = AppColors.primary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .adaptiveIconGradient(colors: [color, color.opacity(0.6)])
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xxSmall)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.15), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Audit Trail Sheet

struct AuditTrailSheet: View {
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject var forensicManager: ForensicManager
    var onExport: () -> Void
    @Environment(\.dismiss) private var dismiss
    private static let freeViewLimit = 10

    private var visibleEntries: [ForensicManager.AuditEntry] {
        let reversed = forensicManager.auditLog.reversed()
        if storeManager.isProfessional {
            return Array(reversed)
        }
        return Array(reversed.prefix(Self.freeViewLimit))
    }

    private var hasMore: Bool {
        !storeManager.isProfessional && forensicManager.auditLog.count > Self.freeViewLimit
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audit Trail")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
                if storeManager.isProfessional {
                    Button("Export") { onExport() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Export (Pro)") { storeManager.showPaywall = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.purple)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if forensicManager.auditLog.isEmpty {
                VStack(spacing: Spacing.medium) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundColor(AppColors.secondary.opacity(0.4))
                    Text("No audit entries yet")
                        .font(Typography.headline)
                        .foregroundColor(AppColors.secondary)
                    Text("Actions like importing files, tagging evidence, and verifying hashes are recorded here.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                HStack {
                    if storeManager.isProfessional {
                        Text("\(forensicManager.auditLog.count) entries")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    } else {
                        Text("Showing \(min(forensicManager.auditLog.count, Self.freeViewLimit)) of \(forensicManager.auditLog.count) entries")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                    Spacer()
                    let status = forensicManager.integrityStatus
                    switch status {
                    case .verified:
                        Label("Chain Verified", systemImage: "checkmark.seal.fill")
                            .font(Typography.caption1)
                            .foregroundColor(.green)
                    case .tampered:
                        Label("TAMPERED", systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.caption1)
                            .foregroundColor(.red)
                    case .noData:
                        Text("No data")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    case .unknown:
                        Button("Verify Integrity") {
                            _ = forensicManager.verifyAuditLogIntegrity()
                        }
                        .font(Typography.caption1)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, Spacing.xSmall)

                List(visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(entry.sequence)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(AppColors.secondary)
                            Text(entry.action)
                                .font(Typography.callout)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(Typography.caption1)
                                .foregroundColor(AppColors.secondary)
                                .lineLimit(2)
                        }
                        if !entry.examiner.isEmpty {
                            Text("by \(entry.examiner)")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary.opacity(0.7))
                        }
                        Text(entry.entryHash.prefix(16) + "...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(AppColors.secondary.opacity(0.4))
                    }
                    .padding(.vertical, 2)
                }

                if hasMore {
                    HStack {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.purple)
                        Text("Upgrade to Professional to view all \(forensicManager.auditLog.count) entries and export.")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        Spacer()
                        Button("Upgrade") { storeManager.showPaywall = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding()
                    .background(Color.purple.opacity(0.05))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 550)
        #endif
    }
}

#if os(iOS)
private struct ReviewImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onCompletion: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content.background(
            Color.clear.fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false,
                onCompletion: onCompletion
            )
        )
    }
}
#endif
