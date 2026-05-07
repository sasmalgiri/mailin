import SwiftUI
import UniformTypeIdentifiers
import StoreKit
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
    @ObservedObject private var sharePlayManager = SharePlayManager.shared
    @Environment(\.windowSizeClass) private var sizeClass
    @AppStorage("defaultSenderEmail") private var defaultSenderEmail = ""
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @AppStorage("autoDetectSender") private var autoDetectSender = true
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var modelVM: ParsedEmailListViewModel
    @State private var showSpinner = false
    @State private var parseFailed = false
    @State private var parsingObserver: NSObjectProtocol?
    @State private var selectedEmailIDs = Set<UUID>()
    @State private var showNewImportConfirmation = false
    @State private var selectedFolder: String?
    @State private var selectedClusterFilter: String?
    @State private var bottomPanelHeight: CGFloat = 250
    @State private var dragStartHeight: CGFloat = 250
    #if os(iOS)
    @State private var showFileImporter = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showIOSSettings = false
    @State private var showReviewImporter = false
    @State private var showFiltersSheet = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @ObservedObject private var predictiveEngine = PredictiveCodingEngine.shared
    @ObservedObject private var custodianManager = CustodianManager.shared
    @ObservedObject private var reviewBatchManager = ReviewBatchManager.shared

    init() {
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
                        text: "Could not parse this file. Supported formats: .mbox, .eml, .emlx, .msg, .pst, .ost, .zip",
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
                            try? data.write(to: tempFile)
                            resolveAndHandleSelectedFile(tempFile)
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
                                let extracted = viewModel.extractMailFilesFromZip(at: url)
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
        .onChange(of: modelVM.filteredEmails.count) { handleFilteredChange() }
        .onAppear { handleAppear() }
        .onDisappear { handleDisappear() }
        .task { sharePlayManager.listenForSessions() }
        .onReceive(NotificationCenter.default.publisher(for: .dataClearedByUser)) { _ in handleDataCleared() }
        .onReceive(NotificationCenter.default.publisher(for: .detectMetadata)) { _ in viewModel.autoDetectMetadata() }
        .onReceive(NotificationCenter.default.publisher(for: .triggerFileImportFromShortcut)) { _ in openPanelFallback() }
        .onReceive(NotificationCenter.default.publisher(for: .spotlightEmailSelected)) { notification in
            if let emailID = notification.object as? UUID {
                selectedEmailIDs = [emailID]
            }
        }
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
                allEmails: modelVM.allEmails,
                filteredEmails: modelVM.filteredEmails,
                selectedEmails: modelVM.filteredEmails.filter { selectedEmailIDs.contains($0.id) },
                searchContext: modelVM.searchText
            )
            .environmentObject(storeManager)
            #if os(macOS)
            .resizableSheet()
            #else
            .presentationDetents([.large])
            #endif
        }
        .sheet(isPresented: $appState.showReplyStatsSheet) {
            ReplyStatsView(replyData: modelVM.replyFrequency(for: viewModel.senderEmail))
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
                .resizableSheet()
        }
        .sheet(isPresented: $appState.showAnalytics) {
            EmailAnalyticsView(emails: modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails)
                #if os(macOS)
                .resizableSheet()
                #else
                .presentationDetents([.large])
                #endif
        }
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
                .resizableSheet()
        }
        .alert("Start New Import?", isPresented: $showNewImportConfirmation) {
            Button("Clear & Start Fresh", role: .destructive) {
                NotificationCenter.default.post(name: .dataClearedByUser, object: nil)
                EmailPersistence.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your current emails and return to the welcome screen. You can re-import anytime.")
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Spacing.xSmall) {
                if collabManager.isEnabled && collabManager.newImportCount > 0 {
                    collaborationBanner
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .animation(.easeInOut, value: collabManager.newImportCount)
                }
                if sharePlayManager.isSessionActive {
                    sharePlayBanner
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .animation(.easeInOut, value: sharePlayManager.isSessionActive)
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
        #if os(iOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "mbox"),
                UTType(filenameExtension: "eml"),
                UTType(filenameExtension: "emlx"),
                UTType(filenameExtension: "msg"),
                UTType(filenameExtension: "pst"),
                UTType(filenameExtension: "ost"),
                UTType(filenameExtension: "zip")
            ].compactMap { $0 },
            allowsMultipleSelection: true
        ) { result in
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
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .fileImporter(
            isPresented: $showReviewImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
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
        }
        #endif
    }

    // MARK: - Layout
    @ViewBuilder
    private var mainLayout: some View {
        #if os(macOS)
        NavigationSplitView {
            leftSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
                .liquidGlassSidebar()
        } content: {
            if modelVM.showParsedList {
                ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 400, max: 700)
            } else {
                Color.clear
                    .frame(width: 0)
            }
        } detail: {
            VStack(spacing: 0) {
                if !modelVM.showParsedList {
                    emptyPlaceholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectedEmailIDs.count == 1,
                   let selectedID = selectedEmailIDs.first,
                   let email = modelVM.filteredEmails.first(where: { $0.id == selectedID }) {
                    EmailDetailView(
                        email: email,
                        allEmails: modelVM.filteredEmails,
                        onNavigate: { newID in selectedEmailIDs = [newID] },
                        searchText: modelVM.searchText
                    )
                    .id(selectedID)
                } else if selectedEmailIDs.count == 2 {
                    let pair = Array(selectedEmailIDs)
                    let emailA = modelVM.filteredEmails.first(where: { $0.id == pair[0] })
                    let emailB = modelVM.filteredEmails.first(where: { $0.id == pair[1] })
                    if let a = emailA, let b = emailB {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Comparing 2 emails")
                                    .font(Typography.headline)
                                Spacer()
                                Button("Show Batch Actions") {
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

                if appState.dockedBottomPanel != nil && modelVM.showParsedList && !currentEmailsForDock.isEmpty {
                    dockedBottomPanelView
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if viewModel.isParsed {
                    Button { appState.showAIAssistant = true } label: {
                        Label("AI Assistant", systemImage: "sparkles")
                    }

                    Button { appState.showAnalytics = true } label: {
                        Label("Analytics", systemImage: "chart.bar")
                    }

                    Button { forensicManager.isEnabled.toggle() } label: {
                        Label("Forensic", systemImage: forensicManager.isEnabled ? "shield.checkered" : "shield")
                    }

                    if #available(macOS 15, iOS 17, *) {
                        Button {
                            if sharePlayManager.isSessionActive {
                                sharePlayManager.endSession()
                            } else {
                                sharePlayManager.startSession()
                            }
                        } label: {
                            Label(
                                sharePlayManager.isSessionActive ? "End SharePlay" : "SharePlay",
                                systemImage: sharePlayManager.isSessionActive ? "shareplay.slash" : "shareplay"
                            )
                        }
                        .help(Text(verbatim: sharePlayManager.isSessionActive
                              ? "End collaborative review session (\(sharePlayManager.participantCount) participants)"
                              : "Start a SharePlay session to review emails together"))
                    }
                }
            }
        }
        .liquidGlassToolbar()
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

    // MARK: - iPhone Layout (Compact)
    #if os(iOS)
    private var iPhoneLayout: some View {
        NavigationStack {
            Group {
                if modelVM.showParsedList {
                    ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
                } else {
                    leftSidebar
                }
            }
            .navigationTitle(modelVM.showParsedList ? "Emails" : "mailin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if modelVM.showParsedList {
                        Button { showFiltersSheet = true } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.isParsed {
                        Button { appState.showAIAssistant = true } label: {
                            Image(systemName: "sparkles")
                        }
                        .accessibilityLabel("AI Assistant")
                        Button { appState.showAnalytics = true } label: {
                            Image(systemName: "chart.bar")
                        }
                        .accessibilityLabel("Analytics")
                        Button { forensicManager.isEnabled.toggle() } label: {
                            Image(systemName: forensicManager.isEnabled ? "shield.checkered" : "shield")
                        }
                        .accessibilityLabel(forensicManager.isEnabled ? "Disable Forensic Mode" : "Enable Forensic Mode")
                        if #available(macOS 15, iOS 17, *) {
                            Button {
                                if sharePlayManager.isSessionActive {
                                    sharePlayManager.endSession()
                                } else {
                                    sharePlayManager.startSession()
                                }
                            } label: {
                                Image(systemName: sharePlayManager.isSessionActive ? "shareplay.slash" : "shareplay")
                            }
                            .accessibilityLabel(sharePlayManager.isSessionActive ? "End SharePlay" : "Start SharePlay")
                        }
                    }
                    Button { showIOSSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: UUID.self) { emailID in
                if let email = modelVM.filteredEmails.first(where: { $0.id == emailID }) {
                    EmailDetailView(
                        email: email,
                        allEmails: modelVM.filteredEmails,
                        onNavigate: { newID in selectedEmailIDs = [newID] },
                        searchText: modelVM.searchText
                    )
                }
            }
            .sheet(isPresented: $showFiltersSheet) {
                NavigationStack {
                    ScrollView {
                        leftSidebar
                    }
                    .navigationTitle("Filters")
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

    // MARK: - iPad Layout (Regular)
    private var iPadLayout: some View {
        NavigationSplitView {
            leftSidebar
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if viewModel.isParsed {
                            Button { appState.showAIAssistant = true } label: {
                                Image(systemName: "sparkles")
                            }
                            .accessibilityLabel("AI Assistant")
                            Button { appState.showAnalytics = true } label: {
                                Image(systemName: "chart.bar")
                            }
                            .accessibilityLabel("Analytics")
                            Button { forensicManager.isEnabled.toggle() } label: {
                                Image(systemName: forensicManager.isEnabled ? "shield.checkered" : "shield")
                            }
                            .accessibilityLabel(forensicManager.isEnabled ? "Disable Forensic Mode" : "Enable Forensic Mode")
                            if #available(macOS 15, iOS 17, *) {
                                Button {
                                    if sharePlayManager.isSessionActive {
                                        sharePlayManager.endSession()
                                    } else {
                                        sharePlayManager.startSession()
                                    }
                                } label: {
                                    Image(systemName: sharePlayManager.isSessionActive ? "shareplay.slash" : "shareplay")
                                }
                                .accessibilityLabel(sharePlayManager.isSessionActive ? "End SharePlay" : "Start SharePlay")
                            }
                        }
                        Button { showIOSSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        } content: {
            if modelVM.showParsedList {
                ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
            } else {
                Text("")
            }
        } detail: {
            if !modelVM.showParsedList {
                emptyPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedEmailIDs.count == 1,
               let selectedID = selectedEmailIDs.first,
               let email = modelVM.filteredEmails.first(where: { $0.id == selectedID }) {
                EmailDetailView(
                    email: email,
                    allEmails: modelVM.filteredEmails,
                    onNavigate: { newID in selectedEmailIDs = [newID] },
                    searchText: modelVM.searchText
                )
                .id(selectedID)
            } else {
                detailPlaceholderWithTools
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

            Spacer()

            if !forensicManager.sourceFileHashes.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                    Text("\(forensicManager.sourceFileHashes.count) file(s) verified")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white.opacity(0.85))
            }

            Text("\(forensicManager.auditLog.count) log entries")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xxSmall)
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.9), Color.red.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
        )
        .adaptiveToolbarBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Forensic mode active. \(forensicManager.caseNumber.isEmpty ? "" : "Case \(forensicManager.caseNumber).")")
    }

    // MARK: - Batch Operations (Multi-Select)
    private var batchOperationsView: some View {
        let selectedEmails = modelVM.filteredEmails.filter { selectedEmailIDs.contains($0.id) }
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
                        .frame(width: 260)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Export selected emails as .eml files")

                if attachmentCount > 0 {
                    Button {
                        downloadAttachmentsFromEmails(selectedEmails)
                    } label: {
                        Label("Download \(attachmentCount) Attachments", systemImage: "arrow.down.circle.fill")
                            .frame(width: 260)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Save all attachments from selected emails")
                }

                Button {
                    let subjects = selectedEmails.compactMap { $0.headers["Subject"] }.joined(separator: "\n")
                    PlatformClipboard.copyString(subjects)
                } label: {
                    Label("Copy Subjects", systemImage: "doc.on.doc")
                        .frame(width: 260)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Copy subject lines to clipboard")

                if forensicManager.isEnabled {
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
                            .frame(width: 260)
                    }
                    #if os(macOS)
                    .menuStyle(.borderedButton)
                    #endif
                }

                Button {
                    selectedEmailIDs.removeAll()
                } label: {
                    Label("Clear Selection", systemImage: "xmark.circle")
                        .frame(width: 260)
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
                    FileUtilsAudit.logError(error, context: "EML Export", path: fileURL.path)
                }
            }
            let finalExported = exportedCount
            let finalFailed = failedCount
            let totalSelected = emails.count
            await MainActor.run {
                if !isPro && totalSelected > finalExported {
                    vm.statusMessage = "Exported \(finalExported) of \(totalSelected) emails (free limit). Upgrade for unlimited."
                    vm.statusColor = .orange
                    self.storeManager.showPaywall = true
                } else if finalFailed > 0 {
                    vm.statusMessage = "Exported \(finalExported) emails. \(finalFailed) failed to save."
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
                    .help("Supports .mbox, .eml, .emlx, .msg, .pst, .ost, and .zip files from Gmail, Thunderbird, Apple Mail, Outlook, and other email clients")
                    .accessibilityLabel("Open email archive")
                    .accessibilityHint("Select mbox, eml, or zip files from Gmail Takeout, Thunderbird, Apple Mail, or other email clients")

                    #if os(macOS)
                    HStack(spacing: Spacing.xSmall) {
                        Button {
                            viewModel.scanForThunderbirdProfiles()
                            if !viewModel.thunderbirdProfiles.isEmpty {
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

                    if !storeManager.isPremium && modelVM.allEmails.count > StoreManager.freeEmailLimit {
                        Button {
                            storeManager.showPaywall = true
                        } label: {
                            HStack(spacing: Spacing.xSmall) {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.orange)
                                Text("Showing \(StoreManager.freeEmailLimit) of \(modelVM.allEmails.count) emails — Upgrade to Pro")
                                    .font(Typography.caption1)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xSmall)
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

                    summarySection
                        .padding(.bottom, Spacing.xxSmall)
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

                    if !modelVM.allEmails.isEmpty {
                        Divider().padding(.horizontal, Spacing.xSmall)
                        FolderTreeView(emails: modelVM.allEmails, selectedFolder: $selectedFolder)
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

    // MARK: - Detail Placeholder with Tools

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
                            detailToolButton(title: "Forensic", icon: forensicManager.isEnabled ? "shield.checkered" : "shield", color: forensicManager.isEnabled ? .orange : .gray) {
                                forensicManager.isEnabled.toggle()
                            }
                            detailToolButton(title: "Topics", icon: "circle.grid.3x3", color: appState.dockedBottomPanel == .topics ? .teal.opacity(0.5) : .teal) {
                                withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics }
                            }
                            detailToolButton(title: "Subjects", icon: "list.bullet.rectangle.portrait", color: appState.dockedBottomPanel == .subjects ? .orange.opacity(0.5) : .orange) {
                                withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .subjects ? nil : .subjects }
                            }
                            detailToolButton(title: "Duplicates", icon: "doc.on.doc", color: .indigo) {
                                appState.showDuplicateManager = true
                            }
                            detailToolButton(title: "Predictive", icon: "brain", color: .pink) {
                                appState.showPredictiveCoding = true
                            }
                            detailToolButton(title: "Replies", icon: "arrow.turn.up.left", color: .green) {
                                appState.showReplyStats = true
                            }
                            detailToolButton(title: "Custodian", icon: "person.badge.key", color: .cyan) {
                                appState.showCustodianPanel = true
                            }
                            detailToolButton(title: storeManager.isProfessional ? "Batches" : "Batches (Pro)", icon: "list.bullet.rectangle", color: .mint) {
                                if storeManager.requireProfessional() {
                                    appState.showReviewBatches = true
                                }
                            }
                            detailToolButton(title: "Compare", icon: "doc.on.doc", color: .indigo) {
                                appState.showArchiveComparison = true
                            }
                            detailToolButton(title: "Report", icon: "doc.text.magnifyingglass", color: .red) {
                                appState.showInvestigationReport = true
                            }
                            detailToolButton(title: "Export", icon: "square.and.arrow.up", color: .brown) {
                                exportFilteredEmailsAsEML()
                            }
                            detailToolButton(title: "Settings", icon: "gearshape", color: .gray) {
                                #if os(macOS)
                                openSettings()
                                #else
                                showIOSSettings = true
                                #endif
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

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailToolButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxSmall) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppColors.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.small)
            .background(color.opacity(0.06))
            .cornerRadius(CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var currentEmailsForDock: [MBOXParser.RawEmail] {
        modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
    }

    // MARK: - Docked Bottom Panel (Topics / Subjects)

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
                    TopicClustersView(
                        emails: currentEmailsForDock,
                        selectedClusterFilter: $selectedClusterFilter,
                        clusterFilterIDs: $modelVM.clusterFilterIDs
                    )
                case .subjects:
                    SubjectsListView(
                        emails: currentEmailsForDock,
                        clusterFilterIDs: $modelVM.clusterFilterIDs
                    )
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
            if viewModel.duplicatesRemoved > 0 {
                HStack(spacing: Spacing.xxSmall) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.info)
                    Text("\(viewModel.duplicatesRemoved) duplicates removed")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.info)
                }
            }
            HStack(spacing: Spacing.small) {
                Label("\(modelVM.filteredEmails.count) Emails", systemImage: "chart.bar.fill")
                    .font(Typography.title3)
                    .foregroundColor(AppColors.secondary)
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
            HStack(spacing: Spacing.xSmall) {
                DatePicker("", selection: $modelVM.startDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    .accessibilityLabel("Start date filter")
                    .onChange(of: modelVM.startDate) { _, _ in modelVM.applyFilters() }
                DatePicker("", selection: $modelVM.endDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    .accessibilityLabel("End date filter")
                    .onChange(of: modelVM.endDate) { _, _ in modelVM.applyFilters() }
                Spacer()
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

            if (forensicManager.isEnabled || personaManager.selectedPersona == .legal) && !forensicManager.evidenceTags.isEmpty {
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

                    ForEach(ForensicManager.EvidenceTag.allCases.filter { $0 != .none }, id: \.self) { tag in
                        let count = forensicManager.taggedCount(for: tag)
                        if count > 0 {
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
                Button {
                    exportFilteredEmailsAsEML()
                } label: {
                    Label("Individual .eml files", systemImage: "envelope")
                }
                Button {
                    exportFilteredEmailsAsCSV()
                } label: {
                    Label("Spreadsheet (.csv)", systemImage: "tablecells")
                }
                Divider()
                Button {
                    exportVCard()
                } label: {
                    Label("Contacts (vCard)", systemImage: "person.crop.rectangle.stack")
                }
                Button {
                    exportICS()
                } label: {
                    Label("Calendar Events (ICS)", systemImage: "calendar")
                }
                Button {
                    batchPrintFiltered()
                } label: {
                    Label("Batch Print Text", systemImage: "printer")
                }
                Button {
                    exportSelectedAsTIFF()
                } label: {
                    Label("Export as TIFF Image", systemImage: "photo")
                }
            } label: {
                Label("Export Emails", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CompactSecondaryButtonStyle())
            .help("Export filtered emails")
            .accessibilityLabel("Export filtered emails")

            if forensicManager.isEnabled || personaManager.selectedPersona == .legal {
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

            Spacer()
        }
        .frame(maxWidth: sizeClass == .compact ? 350 : 560)
        .adaptiveHeroBackground()
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
        case .personal, .general: return "All processing happens entirely on your Mac. No data ever leaves your device."
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
            UTType(filenameExtension: "zip")
        ].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select email files (.mbox, .eml, .emlx, .msg, .pst, .ost, .zip) from any email client"

        if panel.runModal() == .OK {
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
        viewModel.parseSelectedFiles(validURLs)
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
        viewModel.parseSelectedFiles([url])
    }

    private static let freeExportLimit = 10

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
        let allFiltered = modelVM.filteredEmails
        let isPro = storeManager.isPremium
        let emailsToExport = isPro ? allFiltered : Array(allFiltered.prefix(Self.freeExportLimit))
        let vm = viewModel
        Task.detached(priority: .userInitiated) {
            var usedNames = Set<String>()
            var exportedCount = 0
            var failedCount = 0
            for (index, email) in emailsToExport.enumerated() {
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
                    FileUtilsAudit.logError(error, context: "EML Export", path: fileURL.path)
                }
            }
            let finalExported = exportedCount
            let finalFailed = failedCount
            let totalAvailable = allFiltered.count
            await MainActor.run {
                if !isPro && totalAvailable > Self.freeExportLimit {
                    vm.statusMessage = "Exported \(finalExported) of \(totalAvailable) emails (free limit). Upgrade for unlimited."
                    vm.statusColor = .orange
                    self.storeManager.showPaywall = true
                } else if finalFailed > 0 {
                    vm.statusMessage = "Exported \(finalExported) emails. \(finalFailed) failed to save."
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

    private func exportFilteredEmailsAsCSV() {
        let allEmails = modelVM.filteredEmails
        guard !allEmails.isEmpty else { return }
        let isPro = storeManager.isPremium
        let emails = isPro ? allEmails : Array(allEmails.prefix(Self.freeExportLimit))

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin_export_\(emails.count)_emails.csv"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_export_\(emails.count)_emails.csv")
        #endif

        let vm = viewModel
        let emailCount = emails.count
        let totalCount = allEmails.count
        Task.detached(priority: .userInitiated) {
            func csvEscape(_ s: String) -> String {
                let sanitized = s
                    .replacingOccurrences(of: "\"", with: "\"\"")
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                return "\"" + sanitized + "\""
            }

            var csv = "Date,From,To,CC,Subject,Type,Labels,Has Attachments,Attachment Count,Risk Score,Body Preview\n"
            for email in emails {
                let date = email.headers["Date"] ?? ""
                let from = email.headers["From"] ?? ""
                let to = email.headers["To"] ?? ""
                let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
                let subject = email.headers["Subject"] ?? ""
                let tags = email.tags.joined(separator: "; ")
                let hasAtt = email.attachments.isEmpty ? "No" : "Yes"
                let attCount = String(email.attachments.count)
                let risk = ForensicManager.assessRisk(for: email)
                let bodyPreview = String(email.plainBody.prefix(200))

                let row = [date, from, to, cc, subject, email.messageType, tags, hasAtt, attCount, "\(risk.score)", bodyPreview]
                    .map { csvEscape($0) }
                    .joined(separator: ",")
                csv += row + "\n"
            }

            let finalCSV = csv
            await MainActor.run {
                do {
                    try finalCSV.write(to: url, atomically: true, encoding: .utf8)
                    if !isPro && totalCount > emailCount {
                        vm.statusMessage = "Exported \(emailCount) of \(totalCount) emails (free limit). Upgrade for unlimited."
                        vm.statusColor = .orange
                        self.storeManager.showPaywall = true
                    } else {
                        vm.statusMessage = "Exported \(emailCount) emails as CSV."
                        vm.statusColor = .green
                    }
                    #if os(iOS)
                    self.iOSShareFile(at: url)
                    #endif
                } catch {
                    vm.statusMessage = "Failed to export CSV: \(error.localizedDescription)"
                    vm.statusColor = .orange
                }
            }
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
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let csv = forensicManager.exportBulkForensicCSV(emails: emails)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported forensic CSV with \(emails.count) emails."
            viewModel.statusColor = .green
            forensicManager.logAction("Bulk Forensic Export", detail: "Exported \(emails.count) emails as forensic CSV to \(url.lastPathComponent)")
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export forensic CSV: \(error.localizedDescription)"
            viewModel.statusColor = .red
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
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let dat = forensicManager.exportConcordanceDAT(emails: emails)
        do {
            try dat.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported Concordance load file with \(emails.count) records."
            viewModel.statusColor = .green
            forensicManager.logAction("Concordance Export", detail: "Exported \(emails.count) emails as Concordance .dat")
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportTaggedOnly() {
        let taggedIDs = Set(forensicManager.evidenceTags.keys)
        let taggedEmails = (modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails).filter { taggedIDs.contains($0.id) }
        guard !taggedEmails.isEmpty else {
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
        let csv = forensicManager.exportBulkForensicCSV(emails: taggedEmails)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported \(taggedEmails.count) tagged emails."
            viewModel.statusColor = .green
            forensicManager.logAction("Tagged Export", detail: "Exported \(taggedEmails.count) tagged emails")
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    // MARK: - New Export Actions

    private func exportVCard() {
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let vcards = ExportManager.exportContacts(from: emails)
        guard !vcards.isEmpty else {
            viewModel.statusMessage = "No contacts found to export."
            viewModel.statusColor = .orange
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "contacts.vcf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contacts.vcf")
        #endif
        do {
            try vcards.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported contacts as vCard."
            viewModel.statusColor = .green
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export contacts: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportICS() {
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let ics = ExportManager.exportCalendarEvents(from: emails)
        guard !ics.isEmpty else {
            viewModel.statusMessage = "No calendar events found in emails."
            viewModel.statusColor = .orange
            return
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "events.ics"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("events.ics")
        #endif
        do {
            try ics.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported calendar events as ICS."
            viewModel.statusColor = .green
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export events: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportHashManifest() {
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let csv = forensicManager.exportHashManifest(emails)
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hash_manifest_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash_manifest.csv")
        #endif
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported hash manifest for \(emails.count) emails."
            viewModel.statusColor = .green
            forensicManager.logAction("Hash Manifest Export", detail: "Exported hash manifest for \(emails.count) emails")
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export hash manifest: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func batchPrintFiltered() {
        let emails = modelVM.filteredEmails
        guard !emails.isEmpty else { return }
        let text = ExportManager.batchPrintText(emails: emails)
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "batch_print_\(emails.count)_emails.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch_print.txt")
        #endif
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported batch print file with \(emails.count) emails."
            viewModel.statusColor = .green
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportSelectedAsTIFF() {
        let emails = modelVM.filteredEmails
        guard !emails.isEmpty else { return }
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
        var savedCount = 0
        for (idx, email) in emails.enumerated() {
            if let tiffData = ExportManager.exportAsTIFF(email: email) {
                let subject = (email.headers["Subject"] ?? "email")
                    .replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
                    .prefix(50)
                let filename = "\(idx + 1)_\(subject).tiff"
                let fileURL = folderURL.appendingPathComponent(filename)
                try? tiffData.write(to: fileURL)
                savedCount += 1
            }
        }
        viewModel.statusMessage = "Exported \(savedCount) emails as TIFF images."
        viewModel.statusColor = .green
        #if os(iOS)
        if savedCount > 0 {
            iOSShareFile(at: folderURL)
        }
        #endif
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
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let result = forensicManager.batchVerifyAllEmails(emails)
        var message = "Integrity: \(result.passed) passed"
        if result.failed > 0 { message += ", \(result.failed) FAILED" }
        if result.unverified > 0 { message += ", \(result.unverified) unverified" }
        viewModel.statusMessage = message
        viewModel.statusColor = result.failed > 0 ? .red : .green
    }

    // MARK: - MSG/PST/Relativity Export

    private func exportMSG() {
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export as MSG"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "msg_export"
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let count = try MSGWriter.writeMultiple(emails: emails, to: url)
                    await MainActor.run {
                        viewModel.statusMessage = "Exported \(count) MSG files."
                        viewModel.statusColor = .green
                    }
                } catch {
                    await MainActor.run {
                        viewModel.statusMessage = "MSG export failed: \(error.localizedDescription)"
                        viewModel.statusColor = .red
                    }
                }
            }
        }
        #else
        guard let first = emails.first, let data = MSGWriter.write(email: first) else {
            viewModel.statusMessage = "MSG export failed."
            viewModel.statusColor = .red
            return
        }
        if let url = PlatformFileSaver.tempFileURL(name: "export.msg", data: data) {
            shareItems = [url]
            showShareSheet = true
        }
        #endif
    }

    private func exportPST() {
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export as PST"
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "export.pst"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let count = try PSTWriter.write(emails: emails, to: url)
                    await MainActor.run {
                        viewModel.statusMessage = "Exported \(count) emails to PST."
                        viewModel.statusColor = .green
                    }
                } catch {
                    await MainActor.run {
                        viewModel.statusMessage = "PST export failed: \(error.localizedDescription)"
                        viewModel.statusColor = .red
                    }
                }
            }
        }
        #else
        do {
            let data = try PSTWriter.writeData(emails: emails)
            if let url = PlatformFileSaver.tempFileURL(name: "export.pst", data: data) {
                shareItems = [url]
                showShareSheet = true
            }
        } catch {
            viewModel.statusMessage = "PST export failed: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
        #endif
    }

    private func exportRelativity() {
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let csv = ExportManager.generateRelativityLoadFile(
            from: emails,
            custodianName: CustodianManager.shared.defaultCustodian,
            caseNumber: forensicManager.caseNumber
        )
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Relativity Load File"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "relativity_loadfile.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                viewModel.statusMessage = "Exported Relativity load file (\(emails.count) records)."
                viewModel.statusColor = .green
            } catch {
                viewModel.statusMessage = "Export failed: \(error.localizedDescription)"
                viewModel.statusColor = .red
            }
        }
        #else
        if let url = PlatformFileSaver.tempFileURL(name: "relativity_loadfile.csv", text: csv) {
            shareItems = [url]
            showShareSheet = true
        }
        #endif
    }

    private func importFromCloud(_ emails: [MBOXParser.RawEmail]) {
        guard !emails.isEmpty else { return }
        viewModel.restoreEmails(emails)
        modelVM.loadFromContentViewModel()
        EmailSearchIndex.shared.buildAsync(from: emails)
        predictiveEngine.buildVectors(from: emails)
        SpotlightIndexer.shared.indexEmails(emails)
        EmailPersistence.save(emails: emails, senderEmail: viewModel.senderEmail)
        viewModel.statusMessage = "Imported \(emails.count) emails from cloud."
        viewModel.statusColor = .green
    }

    // MARK: - State Change Handlers
    private func handleParseStateChange() {
        if modelVM.isParsed {
            modelVM.isPremiumUser = storeManager.isPremium
            modelVM.applyFilters()
            appState.hasParsedEmails = true
            appState.hasFilteredEmails = !modelVM.filteredEmails.isEmpty
        }
    }
    private func handlePremiumChange() {
        modelVM.isPremiumUser = storeManager.isPremium
        if modelVM.isParsed { modelVM.applyFilters() }
    }
    private func handleFilteredChange() {
        appState.hasFilteredEmails = !modelVM.filteredEmails.isEmpty
        let validIDs = Set(modelVM.filteredEmails.map(\.id))
        let stale = selectedEmailIDs.subtracting(validIDs)
        if !stale.isEmpty { selectedEmailIDs.subtract(stale) }
    }

    // MARK: - Lifecycle Handlers
    private func handleAppear() {
        parsingObserver = NotificationCenter.default.addObserver(
            forName: .parsingFinished, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selectedEmailIDs.removeAll()
                modelVM.resetFilters()
                modelVM.loadFromContentViewModel()
                showSpinner = false
                EmailPersistence.save(emails: viewModel.parsedEmails, senderEmail: viewModel.senderEmail)
                EmailSearchIndex.shared.buildAsync(from: viewModel.parsedEmails)
                predictiveEngine.buildVectors(from: viewModel.parsedEmails)
                SpotlightIndexer.shared.indexEmails(viewModel.parsedEmails)

                // Record successful import and prompt for review if appropriate
                if !viewModel.parsedEmails.isEmpty {
                    ReviewPromptManager.recordImport()
                }
            }
        }
        if autoDetectSender && viewModel.senderEmail.isEmpty && !defaultSenderEmail.isEmpty {
            viewModel.senderEmail = defaultSenderEmail
        }
        let restored = EmailPersistence.load()
        if !restored.emails.isEmpty {
            if !restored.senderEmail.isEmpty {
                viewModel.senderEmail = restored.senderEmail
            }
            viewModel.restoreEmails(restored.emails)
            modelVM.loadFromContentViewModel()
            if !EmailSearchIndex.shared.loadFromDisk(emails: restored.emails) {
                EmailSearchIndex.shared.buildAsync(from: restored.emails)
            }
            predictiveEngine.buildVectors(from: restored.emails)
        }
    }

    private func handleDisappear() {
        if let observer = parsingObserver {
            NotificationCenter.default.removeObserver(observer)
            parsingObserver = nil
        }
    }

    private func handleDataCleared() {
        selectedEmailIDs.removeAll()
        modelVM.resetFilters()
        modelVM.allEmails = []
        modelVM.filteredEmails = []
        modelVM.isParsed = false
        modelVM.showParsedList = false
        modelVM.emailCount = 0
        modelVM.replyCountPerSender = [:]
        modelVM.priorityScores = [:]
        viewModel.clearParsedData()
        EmailSearchIndex.shared.clear()
        EmailSearchIndex.shared.deleteDiskCache()
        SpotlightIndexer.shared.removeAllIndexedEmails()
        appState.hasParsedEmails = false
        appState.hasFilteredEmails = false
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
        selectedEmailIDs = Set(modelVM.filteredEmails.map(\.id))
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
        let log = forensicManager.exportAuditLog()
        do {
            try log.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported audit log with \(forensicManager.auditLog.count) entries."
            viewModel.statusColor = .green
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export audit log: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportPrivilegeLog() {
        let content = forensicManager.exportPrivilegeLog(emails: viewModel.parsedEmails)
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "privilege_log_\(forensicManager.caseNumber.isEmpty ? "mailin" : forensicManager.caseNumber).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("privilege_log.txt")
        #endif
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported privilege log."
            viewModel.statusColor = .green
            #if os(iOS)
            iOSShareFile(at: url)
            #endif
        } catch {
            viewModel.statusMessage = "Failed to export privilege log: \(error.localizedDescription)"
            viewModel.statusColor = .red
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

    // MARK: - SharePlay Banner
    private var sharePlayBanner: some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: "shareplay")
                .foregroundColor(.white)
                .font(.footnote)
            Text("SharePlay active")
                .font(Typography.caption1)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Text("\(sharePlayManager.participantCount) participant\(sharePlayManager.participantCount == 1 ? "" : "s")")
                .font(Typography.caption2)
                .foregroundColor(.white.opacity(0.8))
            Button {
                sharePlayManager.endSession()
            } label: {
                Text("End")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 3)
                    .background(.white)
                    .cornerRadius(CornerRadius.small)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xSmall)
        .background(Color.green.opacity(0.85))
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

    private var currentEmails: [MBOXParser.RawEmail] {
        modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showDuplicateManager) {
                DuplicateManagerView(model: modelVM)
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 400)
                    #endif
            }
            .sheet(isPresented: $appState.showPredictiveCoding) {
                PredictiveCodingView(emails: currentEmails, engine: predictiveEngine)
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 450)
                    #endif
            }
            .sheet(isPresented: $appState.showCustodianPanel) {
                CustodianPanelView(emails: currentEmails, manager: custodianManager)
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 400)
                    #endif
            }
            .sheet(isPresented: $appState.showReviewBatches) {
                ReviewBatchPanelView(emails: currentEmails, manager: reviewBatchManager)
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 400)
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
                AttachmentGridView(emails: currentEmails)
                    #if os(macOS)
                    .frame(minWidth: 700, minHeight: 500)
                    #endif
            }
            .sheet(isPresented: $appState.showTimeline) {
                EmailTimelineView(emails: currentEmails)
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showRelationshipGraph) {
                RelationshipGraphView(emails: currentEmails, senderEmail: senderEmail)
                    .resizableSheet()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $appState.showArchiveComparison) {
                ArchiveComparisonSheetWrapper(archiveA: currentEmails)
                    #if os(macOS)
                    .frame(minWidth: 700, minHeight: 500)
                    #endif
            }
            .sheet(isPresented: $appState.showInvestigationReport) {
                InvestigationReportConfigSheet(emails: currentEmails, senderEmail: senderEmail)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 450)
                    #endif
            }
            .modifier(V7SheetsModifier(appState: appState, emails: currentEmails, senderEmail: senderEmail))
    }
}

// MARK: - V7 Sheets Modifier
struct V7SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    var emails: [MBOXParser.RawEmail]
    var senderEmail: String

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showAutomationRules) {
                AutomationRulesView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 500)
                    #endif
            }
            .sheet(isPresented: $appState.showBatchOperations) {
                BatchOperationsView(
                    emails: emails,
                    selectedIDs: .constant(Set<UUID>()),
                    onTagApplied: { _, _ in },
                    onExportRequested: { _, _ in }
                )
                .resizableSheet()
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
            }
            .sheet(isPresented: $appState.showThreadSummarizer) {
                ThreadSummarizerView(threadEmails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 500)
                    #endif
            }
            .sheet(isPresented: $appState.showSmartAlerts) {
                SmartAlertsView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 550, minHeight: 450)
                    #endif
            }
            .modifier(V7ForensicSheetsModifier(appState: appState, emails: emails))
    }
}

struct V7ForensicSheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    var emails: [MBOXParser.RawEmail]

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showEDiscovery) {
                EDiscoveryWorkflowView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 750, minHeight: 550)
                    #endif
            }
            .sheet(isPresented: $appState.showBatesNumbering) {
                BatesConfigView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }
            .sheet(isPresented: $appState.showRedaction) {
                RedactionConfigView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 500)
                    #endif
            }
            .sheet(isPresented: $appState.showGDPRReport) {
                GDPRReportConfigView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }
            .sheet(isPresented: $appState.showChainOfCustody) {
                ChainOfCustodyView(emails: emails)
                    .resizableSheet()
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 500)
                    #endif
            }
    }
}

// MARK: - V8 Sheets Modifier (Intelligence & Polish)
struct V8SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel

    private var currentEmails: [MBOXParser.RawEmail] {
        modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showNearDuplicates) {
                NearDuplicateDetectionView(emails: currentEmails)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showAnomalyDetection) {
                AnomalyDetectionView(emails: currentEmails)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showSmartAutoTagger) {
                SmartAutoTaggerView(emails: currentEmails)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showAIDigest) {
                AIDigestView(emails: currentEmails)
                    .resizableSheet()
            }
    }
}

// MARK: - V9 Sheets Modifier (Dashboard, Security & Workspaces)
struct V9SheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager
    @ObservedObject var modelVM: ParsedEmailListViewModel
    var senderEmail: String

    private var currentEmails: [MBOXParser.RawEmail] {
        modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showExecutiveDashboard) {
                ExecutiveDashboardView(emails: currentEmails)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showReportBuilder) {
                ReportBuilderView(emails: currentEmails)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showKeywordMonitor) {
                KeywordMonitorView(emails: currentEmails)
                    .resizableSheet()
            }
            .sheet(isPresented: $appState.showCommunicationPatterns) {
                CommunicationPatternsView(emails: currentEmails, senderEmail: senderEmail)
                    .resizableSheet()
            }
            .modifier(V9UtilitySheetsModifier(appState: appState))
    }
}

struct V9UtilitySheetsModifier: ViewModifier {
    @Bindable var appState: AppStateManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.showWorkspaceManager) {
                WorkspaceManagerView()
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
    }

    private func handleCommand(_ id: String) {
        switch id {
        case "askAI": appState.showAIAssistant = true
        case "analytics": appState.showAnalytics = true
        case "topicClusters": withAnimation { appState.dockedBottomPanel = appState.dockedBottomPanel == .topics ? nil : .topics }
        case "duplicates": appState.showDuplicateManager = true
        case "predictiveCoding": appState.showPredictiveCoding = true
        case "timeline": appState.showTimeline = true
        case "relationshipGraph": appState.showRelationshipGraph = true
        case "smartAlerts": appState.showSmartAlerts = true
        case "anomalyDetection": appState.showAnomalyDetection = true
        case "autoTagger": appState.showSmartAutoTagger = true
        case "emailDigest": appState.showAIDigest = true
        case "nearDuplicates": appState.showNearDuplicates = true
        case "commPatterns": appState.showCommunicationPatterns = true
        case "dashboard": appState.showExecutiveDashboard = true
        case "keywordMonitor": appState.showKeywordMonitor = true
        case "reportBuilder": appState.showReportBuilder = true
        case "eDiscovery": appState.showEDiscovery = true
        case "batesNumbering": appState.showBatesNumbering = true
        case "redaction": appState.showRedaction = true
        case "gdprReport": appState.showGDPRReport = true
        case "chainOfCustody": appState.showChainOfCustody = true
        case "workspaces": appState.showWorkspaceManager = true
        case "toggleSidebar": appState.toggleSidebar()
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
                    UTType(filenameExtension: "emlx")
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
    @ObservedObject private var forensicManager = ForensicManager.shared
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) private var dismiss

    @State private var examinerName: String = ""
    @State private var reportTitle: String = "Email Investigation Report"
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(AppColors.primary)
                Text("Generate Investigation Report")
                    .font(Typography.headline)
                Spacer()
                Button { dismiss() } label: {
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
                    // Case info
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

                    // Report content summary
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

                    // Summary
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(AppColors.info)
                        Text("Report will analyze \(emails.count) email\(emails.count == 1 ? "" : "s") and generate a multi-page PDF.")
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

                    // Actions
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(SecondaryButtonStyle())

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
                        .disabled(isGenerating)
                    }
                }
                .padding(Spacing.medium)
            }
        }
        .onAppear {
            examinerName = forensicManager.examinerName
            if !forensicManager.caseNumber.isEmpty {
                reportTitle = "Case \(forensicManager.caseNumber) — Investigation Report"
            }
        }
    }

    private func generateReport() {
        isGenerating = true
        generationError = nil

        let title = reportTitle
        let investigator = examinerName

        Task.detached(priority: .userInitiated) {
            let pdfData = InvestigationReportGenerator.generateReport(
                emails: emails,
                title: title,
                investigatorName: investigator
            )

            await MainActor.run {
                isGenerating = false
                saveReport(data: pdfData)
            }
        }
    }

    private func saveReport(data: Data) {
        let safeName = reportTitle.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "_", options: .regularExpression)
        let fileName = "\(safeName).pdf"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    try data.write(to: url, options: .atomic)
                    forensicManager.logAction("Investigation Report", detail: "Generated PDF report for \(emails.count) emails")
                    dismiss()
                } catch {
                    generationError = "Failed to save report: \(error.localizedDescription)"
                }
            }
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            forensicManager.logAction("Investigation Report", detail: "Generated PDF report for \(emails.count) emails")
            dismiss()
        } catch {
            generationError = "Failed to save report: \(error.localizedDescription)"
        }
        #endif
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
