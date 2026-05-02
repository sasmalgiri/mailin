import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppStateManager
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
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

    init() {
        let vm = ContentViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        _modelVM = StateObject(wrappedValue: ParsedEmailListViewModel(viewModel: vm))
    }

    var body: some View {
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
                        text: "Could not parse this file. Make sure it's a valid .mbox or .eml file exported from Gmail, Thunderbird, or Apple Mail.",
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
                        DispatchQueue.main.async {
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
                        guard ext == "mbox" || ext == "eml" || ext == "zip" else { return }
                        DispatchQueue.main.async {
                            if viewModel.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                parseFailed = true
                                return
                            }
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
        .onChange(of: modelVM.isParsed) { _, newValue in
            if newValue {
                modelVM.isPremiumUser = storeManager.isPremium
                modelVM.applyFilters()
                appState.hasParsedEmails = true
                appState.hasFilteredEmails = !modelVM.filteredEmails.isEmpty
            }
        }
        .onChange(of: storeManager.isPremium) { _, newValue in
            modelVM.isPremiumUser = newValue
            if modelVM.isParsed {
                modelVM.applyFilters()
            }
        }
        .onChange(of: modelVM.filteredEmails.count) { _, _ in
            appState.hasFilteredEmails = !modelVM.filteredEmails.isEmpty
            let validIDs = Set(modelVM.filteredEmails.map(\.id))
            let stale = selectedEmailIDs.subtracting(validIDs)
            if !stale.isEmpty {
                selectedEmailIDs.subtract(stale)
            }
        }
        .onAppear {
            parsingObserver = NotificationCenter.default.addObserver(
                forName: .parsingFinished,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    selectedEmailIDs.removeAll()
                    modelVM.resetFilters()
                    modelVM.loadFromContentViewModel()
                    showSpinner = false
                    EmailPersistence.save(emails: viewModel.parsedEmails, senderEmail: viewModel.senderEmail)
                    EmailSearchIndex.shared.buildAsync(from: viewModel.parsedEmails)
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
                EmailSearchIndex.shared.buildAsync(from: restored.emails)
            }
        }
        .onDisappear {
            if let observer = parsingObserver {
                NotificationCenter.default.removeObserver(observer)
                parsingObserver = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataClearedByUser)) { _ in
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
            appState.hasParsedEmails = false
            appState.hasFilteredEmails = false
        }
        .onChange(of: appState.triggerFileImport) { _, newValue in
            if newValue {
                appState.triggerFileImport = false
                openPanelFallback()
            }
        }
        .onChange(of: appState.triggerExport) { _, newValue in
            if newValue {
                appState.triggerExport = false
                if storeManager.requirePremium() {
                    exportFilteredEmailsAsEML()
                }
            }
        }
        .onChange(of: appState.showReplyStats) { _, newValue in
            if newValue {
                appState.showReplyStats = false
                if storeManager.requirePremium() {
                    appState.showReplyStatsSheet = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .detectMetadata)) { _ in
            viewModel.autoDetectMetadata()
        }
        .onChange(of: appState.triggerAuditLogExport) { _, newValue in
            if newValue {
                appState.triggerAuditLogExport = false
                exportAuditLog()
            }
        }
        .onChange(of: appState.triggerForensicCSVExport) { _, newValue in
            if newValue {
                appState.triggerForensicCSVExport = false
                exportBulkForensicCSV()
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.showAIAssistant && enableAIFeatures },
            set: { appState.showAIAssistant = $0 }
        )) {
            AIAssistantView(
                emails: modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails,
                searchContext: modelVM.searchText
            )
            .environmentObject(storeManager)
        }
        .sheet(isPresented: $appState.showReplyStatsSheet) {
            ReplyStatsView(replyData: modelVM.replyFrequency(for: viewModel.senderEmail))
                .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $appState.showAnalytics) {
            EmailAnalyticsView(emails: modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails)
        }
        .sheet(isPresented: $storeManager.showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
    }

    // MARK: - Layout
    @ViewBuilder
    private var mainLayout: some View {
        #if os(macOS)
        NavigationSplitView {
            leftSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            if modelVM.showParsedList {
                ParsedEmailListView(model: modelVM, selectedEmailIDs: $selectedEmailIDs)
            } else {
                emptyPlaceholder
            }
        } detail: {
            if selectedEmailIDs.count == 1,
               let selectedID = selectedEmailIDs.first,
               let email = modelVM.filteredEmails.first(where: { $0.id == selectedID }) {
                EmailDetailView(
                    email: email,
                    allEmails: modelVM.filteredEmails,
                    onNavigate: { newID in selectedEmailIDs = [newID] },
                    searchText: modelVM.searchText
                )
                .id(selectedID)
            } else if selectedEmailIDs.count > 1 {
                batchOperationsView
            } else {
                VStack(spacing: Spacing.medium) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 44))
                        .foregroundStyle(
                            .linearGradient(colors: [AppColors.primary.opacity(0.4), AppColors.primary.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Text("Select an email to preview")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColors.secondary)
                    Text("Click any email in the list, or use arrow keys to navigate")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #else
        NavigationView {
            leftSidebar
            if modelVM.showParsedList {
                VStack(spacing: 0) {
                    HStack {
                        Text("mailin")
                            .font(Typography.title2)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)

                    Divider()

                    ParsedEmailListView(model: modelVM, selectedEmailIDs: .constant(Set<UUID>()))
                }
            } else {
                emptyPlaceholder
            }
        }
        #endif
    }


    // MARK: - Forensic Mode Banner
    private var forensicModeBanner: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("FORENSIC MODE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .tracking(1)

            if !forensicManager.caseNumber.isEmpty {
                Text("Case: \(forensicManager.caseNumber)")
                    .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 10))
                    Text("\(forensicManager.sourceFileHashes.count) file(s) verified")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
            }

            Text("\(forensicManager.auditLog.count) log entries")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xxSmall)
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.9), Color.red.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
        )
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
                .font(.system(size: 48))
                .foregroundStyle(
                    .linearGradient(colors: [AppColors.primary, AppColors.primary.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("\(selectedEmails.count) emails selected")
                .font(Typography.title2)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: Spacing.small) {
                Button {
                    if storeManager.requirePremium() {
                        exportSelectedEmails(selectedEmails)
                    }
                } label: {
                    Label("Export Selected as EML", systemImage: "square.and.arrow.up")
                        .frame(width: 260)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Requires Pro upgrade")

                if attachmentCount > 0 {
                    Button {
                        if storeManager.requirePremium() {
                            downloadAttachmentsFromEmails(selectedEmails)
                        }
                    } label: {
                        Label("Download \(attachmentCount) Attachments", systemImage: "arrow.down.circle.fill")
                            .frame(width: 260)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Save all attachments from selected emails")
                }

                Button {
                    let subjects = selectedEmails.compactMap { $0.headers["Subject"] }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(subjects, forType: .string)
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
                    .menuStyle(.borderedButton)
                }

                Button {
                    selectedEmailIDs.removeAll()
                } label: {
                    Label("Clear Selection", systemImage: "xmark.circle")
                        .frame(width: 260)
                }
                .buttonStyle(CompactSecondaryButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportSelectedEmails(_ emails: [MBOXParser.RawEmail]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder to save exported emails"
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let vm = viewModel
        DispatchQueue.global(qos: .userInitiated).async {
            var usedNames = Set<String>()
            var exportedCount = 0
            var failedCount = 0
            for (index, email) in emails.enumerated() {
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
            DispatchQueue.main.async {
                if failedCount > 0 {
                    vm.statusMessage = "Exported \(exportedCount) emails. \(failedCount) failed to save."
                    vm.statusColor = .orange
                } else {
                    vm.statusMessage = "Exported \(exportedCount) emails to \(folderURL.lastPathComponent)."
                    vm.statusColor = .green
                }
            }
        }
    }

    private func downloadAttachmentsFromEmails(_ emails: [MBOXParser.RawEmail]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save All"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
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
    }

    // Inside leftSidebar view:

    private var leftSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if !modelVM.isParsed && viewModel.loadingProgress == 0 {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                .linearGradient(colors: [personaManager.selectedPersona.accentColor, personaManager.selectedPersona.accentColor.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        VStack(alignment: .leading, spacing: 0) {
                            Text("mailin")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(personaManager.selectedPersona.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(personaManager.selectedPersona.accentColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Your Email Address")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        TextField("e.g. you@example.com", text: $viewModel.senderEmail)
                            .textFieldStyle(.roundedBorder)
                            .disabled(modelVM.isParsed || modelVM.isParsing)
                            .help("Enter the email address you used in these archives. This helps identify which emails you sent vs received.")
                            .accessibilityLabel("Your email address")
                            .accessibilityHint("Enter the email address you used in these archives")
                    }

                    Button {
                        openPanelFallback()
                    } label: {
                        Label("Open Email Archive", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelVM.isParsing)
                    .help("Supports .mbox, .eml, and .zip files from Gmail Takeout, Thunderbird, Apple Mail, Outlook, Postbox, and other standard email clients")
                    .accessibilityLabel("Open email archive")
                    .accessibilityHint("Select mbox, eml, or zip files from Gmail Takeout, Thunderbird, Apple Mail, or other email clients")


                    if viewModel.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: Spacing.xxSmall) {
                            Image(systemName: "arrow.up")
                                .font(Typography.caption2)
                            Text("Enter your email first to get started")
                                .font(Typography.caption2)
                        }
                        .foregroundColor(AppColors.secondary)
                        .padding(.top, Spacing.xxxSmall)
                    }
                }

                if modelVM.isParsed {
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
                }
                stickyFilterButtons
            }
        }
        .frame(
            minWidth: sizeClass == .compact ? 220 : 280,
            idealWidth: sizeClass == .expanded ? 340 : 300,
            maxWidth: sizeClass == .compact ? 260 : 360
        )
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
                                    .font(.system(size: 9))
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
                                        .font(.system(size: 9))
                                        .foregroundColor(tag.color)
                                    Text(tag.rawValue)
                                        .font(Typography.caption1)
                                    Spacer()
                                    Text("\(count)")
                                        .font(Typography.caption2)
                                        .foregroundColor(.secondary)
                                    if modelVM.selectedEvidenceTag == tag {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9))
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

            Button {
                if storeManager.requirePremium() {
                    exportFilteredEmailsAsEML()
                }
            } label: {
                Label(storeManager.isPremium ? "Export as .eml" : "Export .eml (Pro)", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CompactSecondaryButtonStyle())
            .help("Export filtered emails as individual .eml files")
            .accessibilityLabel("Export filtered emails")
            .accessibilityHint("Save filtered emails as individual EML files")

            if forensicManager.isEnabled {
                Menu {
                    Section("Evidence") {
                        Button {
                            exportBulkForensicCSV()
                        } label: {
                            Label("Forensic CSV (Bates + hashes)", systemImage: "tablecells")
                        }
                        Button {
                            exportConcordanceDAT()
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
                    Section("Reports") {
                        Button {
                            exportAuditLog()
                        } label: {
                            Label("Audit Log (tamper-evident)", systemImage: "list.bullet.rectangle")
                        }
                    }
                } label: {
                    Label("Forensic Export", systemImage: "shield.checkered")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .help("Export forensic data: CSV with Bates numbers and hashes, Concordance load files, or the tamper-evident audit log")
                .accessibilityLabel("Forensic export options")
            }
        }
        .padding(.vertical, Spacing.small)
        .padding(.horizontal, Spacing.xSmall)
        .background(AppColors.backgroundSecondary)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: sizeClass == .compact ? Spacing.small : Spacing.large) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: sizeClass == .compact ? 64 : 96, height: sizeClass == .compact ? 64 : 96)
                .shadow(color: .black.opacity(0.12), radius: Shadows.large.radius, y: Shadows.large.y)

            VStack(spacing: Spacing.xSmall) {
                Text(personaManager.config.welcomeTitle)
                    .font(.system(size: sizeClass == .compact ? 22 : 28, weight: .bold, design: .rounded))

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

                onboardingStep(number: "1", icon: "at", title: "Enter your email", subtitle: sizeClass == .compact ? nil : "Type your email address in the sidebar so mailin can identify your sent messages")
                onboardingStep(number: "2", icon: "folder.badge.plus", title: "Import an archive", subtitle: sizeClass == .compact ? nil : "Open .mbox, .eml, or .zip files from Gmail Takeout, Thunderbird, Apple Mail, Outlook, Postbox, and more")
                onboardingStep(number: "3", icon: "line.3.horizontal.decrease.circle", title: personaStep3Title, subtitle: sizeClass == .compact ? nil : personaStep3Subtitle)
                onboardingStep(number: "4", icon: personaStep4Icon, title: personaStep4Title, subtitle: sizeClass == .compact ? nil : personaStep4Subtitle)
            }
            .padding(sizeClass == .compact ? Spacing.medium : Spacing.large)
            .background(.ultraThinMaterial)
            .cornerRadius(CornerRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .stroke(AppColors.separatorLight, lineWidth: 0.5)
            )

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
        .frame(maxWidth: sizeClass == .compact ? 350 : 500)
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
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
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
        let panel = NSOpenPanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                UTType(filenameExtension: "mbox"),
                UTType(filenameExtension: "eml"),
                UTType(filenameExtension: "zip")
            ].compactMap { $0 }
        } else {
            panel.allowedFileTypes = ["mbox", "eml", "zip"]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select .mbox, .eml, or .zip files from Gmail Takeout, Thunderbird, Apple Mail, Outlook, or other email clients"

        if panel.runModal() == .OK {
            let urls = panel.urls
            let resolvedURLs = resolveZipFiles(urls)
            if resolvedURLs.count == 1, let url = resolvedURLs.first {
                resolveAndHandleSelectedFile(url)
            } else if resolvedURLs.count > 1 {
                handleMultipleFiles(resolvedURLs)
            }
        }
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
        let validURLs = urls.filter { ["mbox", "eml"].contains($0.pathExtension.lowercased()) }
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
        } else if ["mbox", "eml"].contains(url.pathExtension.lowercased()) {
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

    private func exportFilteredEmailsAsEML() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select a folder to save .eml files"
        panel.prompt = "Save"

        panel.begin { result in
            if result == .OK, let folderURL = panel.url {
                let emailsToExport = modelVM.filteredEmails
                let vm = viewModel
                DispatchQueue.global(qos: .userInitiated).async {
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
                    DispatchQueue.main.async {
                        if failedCount > 0 {
                            vm.statusMessage = "Exported \(exportedCount) emails. \(failedCount) failed to save."
                            vm.statusColor = .orange
                        } else {
                            vm.statusMessage = "Exported \(exportedCount) emails to \(folderURL.lastPathComponent)."
                            vm.statusColor = .green
                        }
                    }
                }
            }
        }
    }

    // MARK: - Forensic Exports
    private func exportBulkForensicCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "forensic_export_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let csv = forensicManager.exportBulkForensicCSV(emails: emails)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported forensic CSV with \(emails.count) emails."
            viewModel.statusColor = .green
            forensicManager.logAction("Bulk Forensic Export", detail: "Exported \(emails.count) emails as forensic CSV to \(url.lastPathComponent)")
        } catch {
            viewModel.statusMessage = "Failed to export forensic CSV: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportConcordanceDAT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "forensic_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).dat"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let emails = modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails
        let dat = forensicManager.exportConcordanceDAT(emails: emails)
        do {
            try dat.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported Concordance load file with \(emails.count) records."
            viewModel.statusColor = .green
            forensicManager.logAction("Concordance Export", detail: "Exported \(emails.count) emails as Concordance .dat")
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
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tagged_\(forensicManager.caseNumber.isEmpty ? "emails" : forensicManager.caseNumber).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = forensicManager.exportBulkForensicCSV(emails: taggedEmails)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported \(taggedEmails.count) tagged emails."
            viewModel.statusColor = .green
            forensicManager.logAction("Tagged Export", detail: "Exported \(taggedEmails.count) tagged emails")
        } catch {
            viewModel.statusMessage = "Failed to export: \(error.localizedDescription)"
            viewModel.statusColor = .red
        }
    }

    private func exportAuditLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "audit_log_\(forensicManager.caseNumber.isEmpty ? "mailin" : forensicManager.caseNumber).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let log = forensicManager.exportAuditLog()
        do {
            try log.write(to: url, atomically: true, encoding: .utf8)
            viewModel.statusMessage = "Exported audit log with \(forensicManager.auditLog.count) entries."
            viewModel.statusColor = .green
        } catch {
            viewModel.statusMessage = "Failed to export audit log: \(error.localizedDescription)"
            viewModel.statusColor = .red
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(color.opacity(0.8))
                .tracking(0.5)
            if let helpText {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
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
                .font(.system(size: 11))
                .foregroundStyle(
                    .linearGradient(colors: [color, color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .medium))
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
