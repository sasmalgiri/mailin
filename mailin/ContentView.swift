import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppStateManager
    @EnvironmentObject var storeManager: StoreManager
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var modelVM: ParsedEmailListViewModel
    @State private var showSpinner = false
    @State private var parseFailed = false
    @State private var parsingObserver: NSObjectProtocol?

    init() {
        let vm = ContentViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        _modelVM = StateObject(wrappedValue: ParsedEmailListViewModel(viewModel: vm))
    }

    var body: some View {
        ZStack {
            mainLayout

            if showSpinner || (viewModel.loadingProgress > 0 && viewModel.loadingProgress < 1) {
                overlaySpinner
            }

            VStack {
                if parseFailed {
                    InfoBanner(
                        text: "Failed to parse file. Please check your .mbox/.eml file or contact support.",
                        color: AppColors.error, systemImage: "exclamationmark.triangle.fill"
                    ).padding(.top, Spacing.large)
                } else if !modelVM.isParsed {
                    InfoBanner(
                        text: "Select a .mbox or .eml file to start parsing.",
                        color: AppColors.primary, systemImage: "info.circle.fill"
                    ).padding(.top, Spacing.large)
                }
                Spacer()
            }
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
        }
        .onAppear {
            parsingObserver = NotificationCenter.default.addObserver(
                forName: .parsingFinished,
                object: nil,
                queue: .main
            ) { _ in
                modelVM.loadFromContentViewModel()
                showSpinner = false
                EmailPersistence.save(emails: viewModel.parsedEmails, senderEmail: viewModel.senderEmail)
            }
            let restored = EmailPersistence.load()
            if !restored.emails.isEmpty {
                viewModel.senderEmail = restored.senderEmail
                viewModel.restoreEmails(restored.emails)
                modelVM.loadFromContentViewModel()
            }
        }
        .onDisappear {
            if let observer = parsingObserver {
                NotificationCenter.default.removeObserver(observer)
                parsingObserver = nil
            }
        }
        .sheet(isPresented: $appState.showAIAssistant) {
            AIAssistantView(emails: modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails)
                .environmentObject(storeManager)
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
        } detail: {
            if modelVM.showParsedList {
                ParsedEmailListView(model: modelVM)
            } else {
                emptyPlaceholder
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

                    ParsedEmailListView(model: modelVM)
                }
            } else {
                emptyPlaceholder
            }
        }
        #endif
    }


    // Inside leftSidebar view:

    private var leftSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if !modelVM.isParsed && viewModel.loadingProgress == 0 {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(Typography.title2)
                            .foregroundStyle(
                                .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        Text("mailin")
                            .font(Typography.title3)
                        TextField("Your Email", text: $viewModel.senderEmail)
                            .textFieldStyle(.roundedBorder)
                            .disabled(modelVM.isParsed || modelVM.isParsing)
                    }

                    Button {
                        openPanelFallback()
                    } label: {
                        Label("Select .mbox File", systemImage: "folder")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelVM.isParsing)
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
                        Stepper(value: $modelVM.minReplyCount, in: 0...modelVM.maxReplyCount, step: 1, onEditingChanged: { _ in
                            modelVM.applyFilters()
                        }) {
                            Text("\(modelVM.minReplyCount)")
                                .frame(width: 32, alignment: .center)
                        }
                    }

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
        .frame(minWidth: 300, maxWidth: 350)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
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
                DatePicker("", selection: $modelVM.endDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 120)
                Spacer()
            }
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Divider()
            Label("From", systemImage: "arrow.up.forward")
                .font(Typography.headline)
                .foregroundColor(AppColors.sentEmail)
            multiToggleList(items: modelVM.allFromEmails, selection: $modelVM.selectedFromEmails)

            Label("To", systemImage: "arrow.down.backward")
                .font(Typography.headline)
                .foregroundColor(AppColors.receivedEmail)
            multiToggleList(items: modelVM.allToEmails, selection: $modelVM.selectedToEmails)

            if !modelVM.sortedSendersByReplyCount.isEmpty {
                Label("Senders by Reply Count", systemImage: "envelope.arrow.triangle.branch")
                    .font(Typography.headline)
                    .padding(.top, Spacing.xSmall)
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
                                    .foregroundColor(AppColors.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private var stickyFilterButtons: some View {
        HStack(spacing: Spacing.xSmall) {
            Button {
                modelVM.applyFilters()
            } label: {
                Label("Apply", systemImage: "magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                modelVM.resetFilters()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                if storeManager.requirePremium() {
                    exportFilteredEmailsAsEML()
                }
            } label: {
                Label(storeManager.isPremium ? "Export .eml" : "Export .eml (Pro)", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.vertical, Spacing.small)
        .padding(.horizontal, Spacing.xSmall)
        .background(AppColors.backgroundSecondary)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: Spacing.large) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.1), radius: Shadows.medium.radius, y: Shadows.medium.y)

            VStack(spacing: Spacing.xSmall) {
                Text("Welcome to mailin")
                    .font(Typography.title1)

                Text("Analyze your email archives with AI-powered insights")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.small) {
                onboardingStep(number: "1", icon: "envelope", text: "Enter your email address in the sidebar")
                onboardingStep(number: "2", icon: "folder", text: "Select a .mbox or .eml file to import")
                onboardingStep(number: "3", icon: "sparkles", text: "Explore filters, analytics, and AI assistant")
            }
            .padding(Spacing.medium)
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.large)

            HStack(spacing: Spacing.medium) {
                Label("Free to Try", systemImage: "gift.fill")
                Label("Complete Privacy", systemImage: "lock.shield.fill")
                Label("Native Apple AI", systemImage: "brain.head.profile")
            }
            .font(Typography.caption1)
            .foregroundColor(AppColors.secondary)

            Spacer()
        }
        .frame(maxWidth: 450)
    }

    private func onboardingStep(number: String, icon: String, text: String) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: icon)
                .font(Typography.caption1)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(AppColors.primary)
                .clipShape(Circle())
            Text(text)
                .font(Typography.callout)
        }
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

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - File Handling

    private func openPanelFallback() {
        let panel = NSOpenPanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                UTType(filenameExtension: "mbox"),
                UTType(filenameExtension: "eml")
            ].compactMap { $0 }
        } else {
            panel.allowedFileTypes = ["mbox", "eml"]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            resolveAndHandleSelectedFile(url)
        }
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
                for (index, email) in modelVM.filteredEmails.enumerated() {
                    let rawSubject = email.headers["Subject"] ?? "(no-subject)"
                    let safeSubject = rawSubject
                        .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: [.regularExpression])
                        .prefix(30)
                    let filename = "\(index + 1)_\(safeSubject).eml"
                    let fileURL = folderURL.appendingPathComponent(filename)
                    let emlContent = viewModel.exportEmailAsEML(email)
                    do {
                        try FileUtils.writeData(Data(emlContent.utf8), to: fileURL.path)
                    } catch {
                        print("Failed to write \(filename): \(error)")
                        FileUtilsAudit.logError(error, context: "EML Export", path: fileURL.path)
                    }
                }
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
