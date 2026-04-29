import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppStateManager
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var modelVM: ParsedEmailListViewModel
    @State private var showSpinner = false
    @State private var parseFailed = false

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
                        text: "❌ Failed to parse file. Please check your .mbox/.eml file or contact support.",
                        color: .red, systemImage: "exclamationmark.triangle.fill"
                    ).padding(.top, 24)
                } else if !modelVM.isParsed {
                    InfoBanner(
                        text: "📂 Select a .mbox or .eml file to start parsing.",
                        color: .accentColor, systemImage: "info.circle.fill"
                    ).padding(.top, 24)
                }
                Spacer()
            }
        }
        .onChange(of: modelVM.isParsed) { _, newValue in
            if newValue {
                modelVM.applyFilters()
                appState.hasParsedEmails = true
                appState.hasFilteredEmails = !modelVM.filteredEmails.isEmpty
            }
        }
        .onChange(of: modelVM.filteredEmails.count) { _, _ in
            appState.hasFilteredEmails = !modelVM.filteredEmails.isEmpty
        }
        .onAppear {
            NotificationCenter.default.addObserver(
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
        .sheet(isPresented: $appState.showAIAssistant) {
            AIAssistantView(emails: modelVM.filteredEmails.isEmpty ? modelVM.allEmails : modelVM.filteredEmails)
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
                        Text("📨 Mailin")
                            .font(.title2).bold()
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
            VStack(alignment: .leading, spacing: 14) {
                // Show email + file button only BEFORE parsing starts
                if !modelVM.isParsed && viewModel.loadingProgress == 0 {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("mailin")
                            .font(.title3)
                            .fontWeight(.semibold)
                        TextField("Your Email", text: $viewModel.senderEmail)
                            .textFieldStyle(.roundedBorder)
                            .disabled(modelVM.isParsed || modelVM.isParsing)
                    }

                    Button("📂 Select .mbox File") {
                        openPanelFallback()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelVM.isParsing)
                }

                if modelVM.isParsed {
                    HStack(spacing: 8) {
                        Text("Min Reply Count")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Stepper(value: $modelVM.minReplyCount, in: 0...modelVM.maxReplyCount, step: 1, onEditingChanged: { _ in
                            modelVM.applyFilters()
                        }) {
                            Text("\(modelVM.minReplyCount)")
                                .frame(width: 32, alignment: .center)
                        }
                    }

                    summarySection
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .background(Color(NSColor.windowBackgroundColor))
            .zIndex(1)

            if modelVM.isParsed {
                ScrollView {
                    filterSection
                        .padding(.horizontal, 10)
                }
                stickyFilterButtons
            }
        }
        .frame(minWidth: 300, maxWidth: 350)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("📈 \(modelVM.filteredEmails.count) Emails")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Spacer()
                if let start = modelVM.filteredDateRange.0, let end = modelVM.filteredDateRange.1 {
                    Text("\(formatted(start)) – \(formatted(end))")
                        .font(.title3).bold()
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(4)
                }
            }
            HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("📤 From").font(.headline)
            multiToggleList(items: modelVM.allFromEmails, selection: $modelVM.selectedFromEmails)
            Text("📥 To").font(.headline)
            multiToggleList(items: modelVM.allToEmails, selection: $modelVM.selectedToEmails)

            if !modelVM.sortedSendersByReplyCount.isEmpty {
                Text("📬 Senders by Reply Count").font(.headline).padding(.top, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(modelVM.sortedSendersByReplyCount, id: \.email) { entry in
                            HStack {
                                Text(entry.email.prefix(38))
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(entry.count)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private var stickyFilterButtons: some View {
        HStack(spacing: 10) {
            Button("🔎 Apply") {
                modelVM.applyFilters()
            }
            .buttonStyle(.borderedProminent)

            Button("🧹 Clear") {
                modelVM.resetFilters()
            }
            .buttonStyle(.bordered)

            Button("📤 Export .eml") {
                exportFilteredEmailsAsEML()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "envelope.open")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("📬 Upload a .mbox file to begin.")
                .foregroundColor(.gray)
                .font(.headline)
            Spacer()
        }
    }

    private func multiToggleList(items: [String], selection: Binding<[String]>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
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
                        Text(item.prefix(38)).font(.system(size: 12))
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
            VStack(spacing: 16) {
                ProgressView(value: viewModel.loadingProgress)
                    .scaleEffect(1.6)
                    .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                    .shadow(radius: 10)
                Text(viewModel.loadingText.isEmpty
                    ? (parseFailed ? "❌ Failed to parse file." : "📂 Parsing .mbox file…")
                    : viewModel.loadingText)
                    .foregroundColor(.primary)
                    .font(.headline)
                if viewModel.loadingProgress > 0.01 && viewModel.loadingProgress < 0.99 {
                    Text("\(Int(viewModel.loadingProgress * 100))% complete")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.windowBackgroundColor).opacity(0.97))
                    .shadow(radius: 24)
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
                UTType(filenameExtension: "mbox")!,
                UTType(filenameExtension: "eml")!
            ]
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
                        print("❌ Failed to write \(filename): \(error)")
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
    var color: Color = .accentColor
    var systemImage: String? = nil

    var body: some View {
        HStack {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundColor(.white)
            }
            Text(text)
                .foregroundColor(.white)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(color.opacity(0.95))
        .cornerRadius(10)
        .shadow(radius: 6)
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut, value: text)
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
