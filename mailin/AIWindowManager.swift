import SwiftUI
import AppKit

// MARK: - AIMode Enum
enum AIMode: String, CaseIterable, Identifiable {
    case allEmails = "All Emails"
    case filteredEmails = "Filtered Emails"
    var id: String { self.rawValue }
}

// MARK: - AI Window Launcher
struct AIWindowButton: View {
    @ObservedObject var model: ParsedEmailListViewModel
    @EnvironmentObject var storeManager: StoreManager
    @State private var aiMode: AIMode = .filteredEmails
    @State private var aiWindow: NSWindow?
    @State private var windowObserver: NSObjectProtocol?

    var body: some View {
        Menu {
            Button {
                aiMode = .allEmails
                openAIWindow()
            } label: {
                Label("All Emails", systemImage: "tray.full")
            }
            Button {
                aiMode = .filteredEmails
                openAIWindow()
            } label: {
                Label("Filtered Emails", systemImage: "line.3.horizontal.decrease.circle")
            }
        } label: {
            Label("Ask AI", systemImage: "brain.head.profile")
                .font(Typography.callout)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, Spacing.small)
                .padding(.vertical, Spacing.xSmall)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(CornerRadius.medium)
        }
        .help("Open the AI assistant to analyze sentiment, extract topics, detect languages, and more")
        .accessibilityLabel("Ask AI assistant")
        .accessibilityHint("Open AI assistant to analyze your emails")
    }

    private func openAIWindow() {
        if let existing = aiWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let windowWidth = min(680, screenSize.width * 0.45)
        let windowHeight = min(520, screenSize.height * 0.65)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "AI Assistant"
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 400, height: 350)

        let selectedEmails = aiMode == .allEmails ? model.viewModel.parsedEmails : model.filteredEmails

        newWindow.contentView = NSHostingView(rootView:
            AskAIView(mode: aiMode, emails: selectedEmails)
        )

        if let main = NSApp.mainWindow {
            let mainFrame = main.frame
            newWindow.setFrameOrigin(NSPoint(x: mainFrame.maxX + 20, y: mainFrame.minY))
        }

        if let oldObserver = windowObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { _ in
            self.aiWindow = nil
            if let obs = self.windowObserver {
                NotificationCenter.default.removeObserver(obs)
                self.windowObserver = nil
            }
        }

        aiWindow = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - AskAIView Interface
struct AskAIView: View {
    let mode: AIMode
    let emails: [MBOXParser.RawEmail]

    @State private var question: String = ""
    @State private var answer: String = ""
    @State private var loading: Bool = false
    @State private var currentTask: Task<Void, Never>?
    @State private var useFoundationModel = false

    private var foundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelEngine.isAvailable
        }
        #endif
        return false
    }

    private enum LLMStatus {
        case available
        case notEnabled
        case notReady
        case notPossible
    }

    private var foundationModelStatus: LLMStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch FoundationModelEngine.availability {
            case .available:
                return .available
            case .notEnabled:
                return .notEnabled
            case .notReady:
                return .notReady
            case .notEligible:
                return .notPossible
            case .unknown:
                return .notPossible
            }
        }
        #endif
        return .notPossible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "brain.head.profile")
                        .font(Typography.title2)
                        .foregroundStyle(
                            .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                        Text("AI Assistant")
                            .font(Typography.title3)
                        Text(aiEngineLabel)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                Spacer()

                if foundationModelAvailable {
                    Picker("", selection: $useFoundationModel) {
                        Text("Apple AI").tag(true)
                        Text("NLP").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .help("Apple AI uses Apple Intelligence for richer answers. NLP uses faster keyword-based analysis.")
                    .accessibilityLabel("AI engine")
                    .accessibilityHint("Choose between Apple Intelligence or NLP analysis")
                }

                if loading {
                    Button {
                        currentTask?.cancel()
                        currentTask = nil
                        loading = false
                    } label: {
                        Label("Cancel", systemImage: "stop.circle.fill")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel the current AI request")
                }

                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close this window")
                .keyboardShortcut("w", modifiers: .command)
                .accessibilityLabel("Close AI window")
            }

            switch foundationModelStatus {
            case .notEnabled:
                llmNotEnabledBanner
            case .notReady:
                llmNotReadyBanner
            case .available, .notPossible:
                EmptyView()
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Ask a question about your emails")
                    .font(Typography.headline)

                HStack(spacing: Spacing.small) {
                    TextField("e.g. What's the sentiment of my emails?", text: $question)
                        .textFieldStyle(.plain)
                        .font(Typography.body)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.medium)
                        .onSubmit { runQA() }
                        .disabled(loading)
                        .accessibilityLabel("Question input")
                        .accessibilityHint("Type a question about your emails")

                    Button {
                        runQA()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? AppColors.primary : AppColors.secondary.opacity(0.5))
                    .disabled(!canSend)
                    .help("Send your question (or press Return)")
                    .accessibilityLabel(loading ? "Processing" : "Send question")
                }

                if answer.isEmpty && !loading {
                    suggestedQuestions
                }
            }

            resultView

            Spacer()
        }
        .padding(Spacing.large)
        .frame(minWidth: 380, idealWidth: 580, minHeight: 340)
        .background(AppColors.backgroundTertiary)
        .onAppear {
            useFoundationModel = foundationModelAvailable
        }
        .onDisappear {
            currentTask?.cancel()
            currentTask = nil
        }
    }

    private var aiEngineLabel: String {
        let count = emails.count
        let suffix = count == 1 ? "" : "s"
        if useFoundationModel && foundationModelAvailable {
            return "Analyzing \(count) \(mode.rawValue.lowercased()) email\(suffix) with Apple Intelligence"
        }
        return "Analyzing \(count) \(mode.rawValue.lowercased()) email\(suffix) with NLP"
    }

    private var llmNotEnabledBanner: some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: "sparkles")
                .font(Typography.body)
                .foregroundStyle(
                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("Apple Intelligence available but not enabled")
                    .font(Typography.caption1)
                    .fontWeight(.medium)
                Text("Enable it in System Settings for richer AI answers.")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.general") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(Typography.caption2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xxSmall)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(CornerRadius.medium)
    }

    private var llmNotReadyBanner: some View {
        HStack(spacing: Spacing.xSmall) {
            ProgressView()
                .scaleEffect(0.6)
            Text("Apple Intelligence is downloading... NLP available now.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xxSmall)
        .background(AppColors.info.opacity(0.06))
        .cornerRadius(CornerRadius.medium)
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loading
    }

    private var suggestedQuestions: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("Try asking:")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            FlowLayout(spacing: Spacing.xxSmall) {
                SuggestedQuestionChip(text: "Summarize my emails") { question = "Summarize my emails" ; runQA() }
                SuggestedQuestionChip(text: "What's the sentiment?") { question = "What's the sentiment?" ; runQA() }
                SuggestedQuestionChip(text: "Top topics discussed") { question = "What topics are discussed?" ; runQA() }
                SuggestedQuestionChip(text: "People mentioned") { question = "Who are the key people mentioned?" ; runQA() }
                SuggestedQuestionChip(text: "Languages detected") { question = "What languages are used?" ; runQA() }
                SuggestedQuestionChip(text: "Attachment overview") { question = "Tell me about attachments" ; runQA() }
                SuggestedQuestionChip(text: "Conversation threads") { question = "Show me conversation threads" ; runQA() }
                SuggestedQuestionChip(text: "Categorize emails") { question = "Categorize my emails" ; runQA() }
                SuggestedQuestionChip(text: "Scan for phishing") { question = "Scan for phishing or scams" ; runQA() }
                SuggestedQuestionChip(text: "High priority") { question = "Show high priority emails" ; runQA() }
                SuggestedQuestionChip(text: "PII / GDPR scan") { question = "Scan for personal data" ; runQA() }
                SuggestedQuestionChip(text: "Thread summaries") { question = "Summarize conversation threads" ; runQA() }
                SuggestedQuestionChip(text: "Storage analysis") { question = "Show storage analysis" ; runQA() }
            }
        }
        .padding(.top, Spacing.xxSmall)
    }

    // MARK: - Result UI
    @ViewBuilder
    private var resultView: some View {
        if loading {
            HStack(spacing: Spacing.xSmall) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Analyzing...")
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.vertical, Spacing.medium)
        } else if !answer.isEmpty {
            ScrollView {
                Text(answer)
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.backgroundSecondary)
                    .cornerRadius(CornerRadius.large)
            }
            .frame(minHeight: 160, maxHeight: 320)
        }
    }

    // MARK: - QA Logic
    private func runQA() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentTask?.cancel()
        answer = ""
        loading = true

        let currentQuestion = question
        let emailsCopy = emails

        if useFoundationModel && foundationModelAvailable && shouldUseFoundationModel(for: currentQuestion) {
            currentTask = Task {
                defer { self.loading = false }
                let result = await askFoundationModel(currentQuestion, emails: emailsCopy)
                guard !Task.isCancelled else { return }
                withAnimation(AnimationTiming.normal) {
                    self.answer = result
                }
            }
        } else {
            currentTask = Task {
                defer { self.loading = false }
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let answer = AIAssistantView.processNLPQuery(currentQuestion, emails: emailsCopy)
                        continuation.resume(returning: answer)
                    }
                }
                guard !Task.isCancelled else { return }
                withAnimation(AnimationTiming.normal) {
                    self.answer = result
                }
            }
        }
    }

    private func shouldUseFoundationModel(for query: String) -> Bool {
        let lower = query.lowercased()
        let dataOnlyKeywords = ["how many", "date range", "attachment count"]
        return !dataOnlyKeywords.contains(where: { lower.contains($0) })
    }

    private struct TimeoutError: Error {}

    private func askFoundationModel(_ query: String, emails: [MBOXParser.RawEmail]) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await FoundationModelEngine.respond(to: query, emails: emails)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        return AIAssistantView.processNLPQuery(query, emails: emails)
                    }
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                return ""
            } catch is TimeoutError {
                return "Apple Intelligence took too long to respond.\n\nFalling back to NLP analysis:\n\n\(AIAssistantView.processNLPQuery(query, emails: emails))"
            } catch {
                return "Apple Intelligence error: \(error.localizedDescription)\n\nFalling back to NLP analysis:\n\n\(AIAssistantView.processNLPQuery(query, emails: emails))"
            }
        }
        #endif
        return AIAssistantView.processNLPQuery(query, emails: emails)
    }
}

// MARK: - Suggested Question Chip
struct SuggestedQuestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Typography.caption1)
                .foregroundColor(AppColors.primary)
                .padding(.horizontal, Spacing.small)
                .padding(.vertical, Spacing.xxSmall)
                .background(AppColors.primary.opacity(0.08))
                .cornerRadius(CornerRadius.round)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.round)
                        .stroke(AppColors.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask: \(text)")
    }
}

// MARK: - Flow Layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
