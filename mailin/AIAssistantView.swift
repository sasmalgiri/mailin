import SwiftUI
import AppKit
import NaturalLanguage
import UniformTypeIdentifiers

struct AIAssistantView: View {
    let emails: [MBOXParser.RawEmail]
    var searchContext: String = ""

    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    @State private var prompt = ""
    @State private var isProcessing = false
    @State private var conversationHistory: [(query: String, answer: String)] = []
    @State private var selectedEngine: AIEngine = .nlp
    @State private var currentTask: Task<Void, Never>?
    @State private var streamingQuery = ""
    @State private var streamingAnswer = ""

    @State private var openAIAPIKey = KeychainHelper.load(key: "openAIAPIKey")
    @AppStorage("openAIModel") private var openAIModel = "gpt-4o-mini"
    @AppStorage("openAIEndpoint") private var openAIEndpoint = "https://api.openai.com/v1"
    @AppStorage("customModelName") private var customModelName = ""
    @AppStorage("hasConsentedToCloudAI") private var hasConsentedToCloudAI = false
    @State private var showCloudAIConsent = false

    @Environment(\.dismiss) private var dismiss

    private enum AIEngine: String, CaseIterable {
        case appleAI = "Apple AI"
        case openAI = "Cloud AI"
        case nlp = "NLP"
    }

    private var openAIAvailable: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveModel: String {
        openAIModel == "custom" ? customModelName : openAIModel
    }

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
        VStack(spacing: 0) {
            headerView

            switch foundationModelStatus {
            case .notEnabled:
                llmNotEnabledBanner
            case .notReady:
                llmNotReadyBanner
            case .available, .notPossible:
                EmptyView()
            }

            if forensicManager.isEnabled {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "shield.checkered")
                        .foregroundColor(.orange)
                    Text("Forensic Mode — Cloud AI disabled. All analysis is on-device only.")
                        .font(Typography.caption1)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.xxSmall)
                .background(Color.orange.opacity(0.08))
            }

            Divider()
            chatArea
            Divider()
            inputArea
        }
        .frame(minWidth: 420, idealWidth: 620, minHeight: 400, idealHeight: 520)
        .background(AppColors.backgroundTertiary)
        .onAppear {
            if let legacyKey = UserDefaults.standard.string(forKey: "openAIAPIKey"), !legacyKey.isEmpty {
                KeychainHelper.save(key: "openAIAPIKey", value: legacyKey)
                UserDefaults.standard.removeObject(forKey: "openAIAPIKey")
            }
            openAIAPIKey = KeychainHelper.load(key: "openAIAPIKey")
            if foundationModelAvailable {
                selectedEngine = .appleAI
            } else {
                selectedEngine = .nlp
            }
            loadConversation()
        }
        .onDisappear {
            currentTask?.cancel()
            currentTask = nil
            saveConversation()
        }
        .alert("Cloud AI Data Sharing", isPresented: $showCloudAIConsent) {
            Button("I Understand & Agree") {
                hasConsentedToCloudAI = true
                askAI()
            }
            Button("Cancel", role: .cancel) {
                selectedEngine = foundationModelAvailable ? .appleAI : .nlp
            }
        } message: {
            Text("Cloud AI sends your email content (subjects, body text, headers) to \(cloudProviderName) for processing. This data will leave your device and be processed by a third-party AI service.\n\nDo not use Cloud AI with confidential, privileged, or sensitive emails.\n\nOn-device engines (Apple AI, NLP) never send data off-device.")
        }
    }

    // MARK: - LLM Status Banners

    private var llmNotEnabledBanner: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "sparkles")
                .font(Typography.title3)
                .foregroundStyle(
                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("Unlock Apple Intelligence for richer AI answers")
                    .font(Typography.callout)
                    .fontWeight(.medium)
                Text("Apple Intelligence is available on this Mac but not enabled yet. Enable it to get natural language summaries, deeper analysis, and conversational answers.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.general") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(Typography.caption1)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(
            LinearGradient(colors: [Color.blue.opacity(0.06), Color.purple.opacity(0.06)], startPoint: .leading, endPoint: .trailing)
        )
    }

    private var llmNotReadyBanner: some View {
        HStack(spacing: Spacing.small) {
            ProgressView()
                .scaleEffect(0.7)
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text("Apple Intelligence is downloading...")
                    .font(Typography.callout)
                    .fontWeight(.medium)
                Text("The on-device model is being set up. This usually takes a few minutes. NLP analysis is available in the meantime.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.info.opacity(0.06))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(
                        .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Email Assistant")
                        .font(Typography.headline)
                    Text(aiEngineLabel)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }

            Spacer()

            Picker("", selection: $selectedEngine) {
                if foundationModelAvailable {
                    Text("Apple AI").tag(AIEngine.appleAI)
                }
                if openAIAvailable && !forensicManager.isEnabled {
                    Text("Cloud AI").tag(AIEngine.openAI)
                }
                Text("NLP").tag(AIEngine.nlp)
            }
            .pickerStyle(.segmented)
            .frame(width: foundationModelAvailable && openAIAvailable && !forensicManager.isEnabled ? 240 : foundationModelAvailable ? 170 : 0)
            .help(engineHelp)
            .accessibilityLabel("AI engine")
            .opacity(foundationModelAvailable || (openAIAvailable && !forensicManager.isEnabled) ? 1 : 0)
            .onChange(of: forensicManager.isEnabled) { _, enabled in
                if enabled && selectedEngine == .openAI {
                    selectedEngine = foundationModelAvailable ? .appleAI : .nlp
                }
            }

            if isProcessing {
                Button {
                    currentTask?.cancel()
                    currentTask = nil
                    isProcessing = false
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(Typography.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppColors.error)
                .help("Cancel the current AI request")
            }

            Button(action: exportConversation) {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(Typography.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(conversationHistory.isEmpty)
            .accessibilityLabel("Export conversation")
            .accessibilityHint("Save the conversation as a Markdown report")

            Button {
                conversationHistory.removeAll()
                Self.clearSavedConversation()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(Typography.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(conversationHistory.isEmpty)
            .accessibilityLabel("Clear conversation")
            .accessibilityHint("Remove all messages from the conversation")

            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close AI assistant")
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.medium) {
                    if conversationHistory.isEmpty && streamingQuery.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(Array(conversationHistory.enumerated()), id: \.offset) { index, item in
                            chatBubble(query: item.query, answer: item.answer)
                                .id(index)
                        }
                        if !streamingQuery.isEmpty {
                            chatBubble(query: streamingQuery, answer: streamingAnswer.isEmpty ? "Thinking..." : streamingAnswer, isStreaming: true)
                                .id("streaming")
                        }
                    }
                }
                .padding(Spacing.medium)
            }
            .onChange(of: conversationHistory.count) { _, _ in
                if let last = conversationHistory.indices.last {
                    withAnimation(AnimationTiming.normal) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: streamingAnswer) { _, _ in
                if !streamingQuery.isEmpty {
                    withAnimation(AnimationTiming.normal) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.large) {
            Spacer(minLength: Spacing.xxLarge)

            Image(systemName: personaManager.selectedPersona == .forensic ? "magnifyingglass" : "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(
                    .linearGradient(colors: [personaManager.selectedPersona.accentColor, personaManager.selectedPersona.accentColor.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(spacing: Spacing.xSmall) {
                Text(personaAITitle)
                    .font(Typography.title3)
                Text({
                    switch selectedEngine {
                    case .appleAI: return "Powered by Apple Intelligence — 100% on-device"
                    case .openAI: return "Powered by \(effectiveModel) — cloud API"
                    case .nlp: return "Powered by on-device Natural Language Processing"
                    }}())
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
            }

            VStack(spacing: Spacing.xSmall) {
                ForEach(sampleQuestions, id: \.self) { question in
                    Button {
                        prompt = question
                        askAI()
                    } label: {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "sparkle")
                                .font(Typography.caption1)
                                .foregroundStyle(.blue)
                            Text(question)
                                .font(Typography.callout)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(AppColors.primary.opacity(0.4))
                        }
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.medium)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(scale: 1.01)
                    .accessibilityLabel("Ask: \(question)")
                    .accessibilityHint("Send this question to the AI assistant")
                }
            }
            .frame(maxWidth: 420)

            Spacer(minLength: Spacing.xxLarge)
        }
    }

    private var sampleQuestions: [String] {
        var questions: [String] = []

        if !emails.isEmpty {
            let topSender = Dictionary(grouping: emails, by: { $0.headers["From"] ?? "" })
                .max(by: { $0.value.count < $1.value.count })
            if let sender = topSender, sender.value.count >= 2 {
                let name = sender.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? sender.key
                questions.append("Tell me about emails from \(name)")
            }

            let topics = EmailNLPEngine.extractTopics(from: Array(emails.prefix(200)), limit: 1)
            if let topTopic = topics.first {
                questions.append("What's discussed about \(topTopic.word)?")
            }

            let recentWeek = emails.filter { email in
                guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return false }
                return d > weekAgo
            }
            if recentWeek.count >= 2 {
                questions.append("Summarize emails from last week")
            }
        }

        questions.append(contentsOf: personaManager.config.sampleAIQueries)

        return Array(questions.prefix(8))
    }

    // MARK: - Chat Bubble

    private func chatBubble(query: String, answer: String, isStreaming: Bool = false) -> some View {
        VStack(spacing: Spacing.small) {
            // User message
            HStack {
                Spacer(minLength: Spacing.xxLarge)
                VStack(alignment: .trailing, spacing: Spacing.xxSmall) {
                    Text(query)
                        .font(Typography.body)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .foregroundColor(.white)
                        .background(
                            LinearGradient(colors: [.blue, .blue.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .cornerRadius(CornerRadius.large)
                }
                .accessibilityLabel("Your question: \(query)")
            }

            // AI response
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    HStack(spacing: Spacing.xxSmall) {
                        Image(systemName: "brain.head.profile")
                            .font(Typography.caption1)
                            .foregroundStyle(.purple)
                        Text("AI")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        if isStreaming {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(answer)
                        .font(Typography.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.large)
                        .opacity(isStreaming && answer == "Thinking..." ? 0.5 : 1.0)
                        .accessibilityLabel(isStreaming ? "AI is thinking" : "AI response: \(answer)")
                }
                Spacer(minLength: Spacing.xxLarge)
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: Spacing.small) {
            TextField("Ask about your emails...", text: $prompt)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(.horizontal, Spacing.small)
                .padding(.vertical, Spacing.xSmall)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.medium)
                .onSubmit { askAI() }
                .accessibilityLabel("Question input")
                .accessibilityHint("Type a question about your emails, then press Return to send")

            Button(action: askAI) {
                Group {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? AppColors.primary : AppColors.secondary.opacity(0.5))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel(isProcessing ? "Processing query" : "Send question")
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(AppColors.backgroundPrimary)
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    private var personaAITitle: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Investigate your email evidence"
        case .legal: return "Analyze documents for review"
        case .itAdmin: return "Diagnose email infrastructure"
        case .journalist: return "Discover patterns and stories"
        case .personal, .general: return "Ask anything about your emails"
        }
    }

    // MARK: - AI Engine Label

    private var aiEngineLabel: String {
        let count = emails.count
        let suffix = count == 1 ? "" : "s"
        switch selectedEngine {
        case .appleAI:
            return "Analyzing \(count) email\(suffix) with Apple Intelligence (on-device)"
        case .openAI:
            return "Analyzing \(count) email\(suffix) with \(effectiveModel) (cloud)"
        case .nlp:
            return "Analyzing \(count) email\(suffix) with on-device NLP"
        }
    }

    private var engineHelp: String {
        switch selectedEngine {
        case .appleAI: return "Apple Intelligence — on-device, private"
        case .openAI: return "Cloud AI — sends email data to API provider"
        case .nlp: return "NLP — fast, on-device keyword analysis"
        }
    }

    private var cloudProviderName: String {
        let endpoint = openAIEndpoint.lowercased()
        if endpoint.contains("openai.com") { return "OpenAI (\(openAIEndpoint))" }
        if endpoint.contains("anthropic.com") { return "Anthropic (\(openAIEndpoint))" }
        if endpoint.contains("localhost") || endpoint.contains("127.0.0.1") { return "a local AI server (\(openAIEndpoint))" }
        return "a third-party AI provider at \(openAIEndpoint)"
    }

    // MARK: - AI Logic

    private func askAI() {
        let query = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        if selectedEngine == .openAI && !hasConsentedToCloudAI {
            showCloudAIConsent = true
            return
        }

        currentTask?.cancel()
        isProcessing = true
        let currentQuery = query
        prompt = ""

        let context = searchContext
        let emailsCopy = emails
        let engine = selectedEngine
        let apiKey = openAIAPIKey
        let model = effectiveModel
        let endpoint = openAIEndpoint

        switch engine {
        case .appleAI:
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }
                streamingQuery = currentQuery
                streamingAnswer = ""
                var answer = await askFoundationModelStreaming(currentQuery)
                guard !Task.isCancelled else { return }
                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                streamingQuery = ""
                streamingAnswer = ""
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer))
                }
            }

        case .openAI:
            let history = conversationHistory
            currentTask = Task {
                defer { isProcessing = false }
                var answer: String
                do {
                    answer = try await OpenAIEngine.respond(
                        to: currentQuery,
                        emails: emailsCopy,
                        apiKey: apiKey,
                        model: model,
                        endpoint: endpoint,
                        priorTurns: history.suffix(4).map { (query: $0.query, answer: $0.answer) }
                    )
                } catch {
                    answer = "Cloud AI error: \(error.localizedDescription)\n\nFalling back to NLP:\n\n\(Self.processNLPQuery(currentQuery, emails: emailsCopy))"
                }
                guard !Task.isCancelled else { return }
                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "🔍 Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer))
                }
            }

        case .nlp:
            let priorContext = conversationHistory.suffix(3).map { "Q: \($0.query)\nA: \($0.answer)" }.joined(separator: "\n\n")
            currentTask = Task {
                defer { isProcessing = false }
                let answer = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var result = AIAssistantView.processNLPQuery(currentQuery, emails: emailsCopy, priorContext: priorContext)
                        if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            result = "🔍 Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + result
                        }
                        continuation.resume(returning: result)
                    }
                }
                guard !Task.isCancelled else { return }
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer))
                }
            }
        }
    }

    private struct TimeoutError: Error {}

    private func askFoundationModelStreaming(_ query: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await FoundationModelEngine.respondStreaming(to: query, emails: emails) { partial in
                            streamingAnswer = partial
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(60))
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        return Self.processNLPQuery(query, emails: emails)
                    }
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                return streamingAnswer.isEmpty ? "" : streamingAnswer
            } catch is TimeoutError {
                let partial = streamingAnswer
                if !partial.isEmpty {
                    return partial + "\n\n(Response timed out — partial result shown)"
                }
                return "Apple Intelligence took too long to respond.\n\nFalling back to NLP analysis:\n\n\(Self.processNLPQuery(query, emails: emails))"
            } catch {
                return "Apple Intelligence error: \(error.localizedDescription)\n\nFalling back to NLP analysis:\n\n\(Self.processNLPQuery(query, emails: emails))"
            }
        }
        #endif
        return Self.processNLPQuery(query, emails: emails)
    }

    private func askFoundationModel(_ query: String) async -> String {
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
                        return Self.processNLPQuery(query, emails: emails)
                    }
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                return ""
            } catch is TimeoutError {
                return "Apple Intelligence took too long to respond.\n\nFalling back to NLP analysis:\n\n\(Self.processNLPQuery(query, emails: emails))"
            } catch {
                return "Apple Intelligence error: \(error.localizedDescription)\n\nFalling back to NLP analysis:\n\n\(Self.processNLPQuery(query, emails: emails))"
            }
        }
        #endif
        return Self.processNLPQuery(query, emails: emails)
    }

    static func processNLPQuery(_ query: String, emails: [MBOXParser.RawEmail], priorContext: String = "") -> String {
        var lower = query.lowercased()
        let resolved = resolveConversationContext(query: lower, priorContext: priorContext)
        lower = resolved.query
        let carriedNames = resolved.names
        let carriedTopics = resolved.topics

        // MARK: - Scope emails via RAG when query has specific terms beyond the handler keyword
        let extraTerms = EmailNLPEngine.extractSearchTerms(from: lower)
        let handlerKeywords: Set<String> = [
            "sentiment", "tone", "mood", "feeling", "emotion", "people", "person", "entities",
            "names", "topic", "keyword", "discuss", "language", "translate", "contact", "insight",
            "who", "most", "frequent", "subject", "common", "date", "range", "reply", "statistic",
            "attachment", "phishing", "scam", "suspicious", "spam", "fraud", "classify", "categorize",
            "category", "pii", "personal", "gdpr", "compliance", "sensitive", "privacy", "priority",
            "important", "urgent", "missed", "action", "summarize", "thread", "conversation", "summary",
            "overview", "analyze", "cleanup", "storage", "disk", "space", "biggest", "relationship",
            "communication", "mention", "positive", "negative",
        ]
        let specificTerms = extraTerms.filter { !handlerKeywords.contains($0.lowercased()) }
        let dateRange = EmailNLPEngine.parseDateRange(from: lower)

        let scopedEmails: [MBOXParser.RawEmail]
        var scopeLabel = ""
        if !specificTerms.isEmpty || dateRange != nil {
            // Try search index first (instant), fall back to linear scan
            let indexResults = !specificTerms.isEmpty
                ? EmailSearchIndex.shared.hybridSearch(query: lower, terms: specificTerms, limit: 200)
                : []
            let results: [EmailNLPEngine.SearchResult]
            if indexResults.count >= 3 {
                results = indexResults
            } else {
                results = EmailNLPEngine.searchWithDateFilter(terms: specificTerms, in: emails, dateRange: dateRange, limit: 200)
            }

            if results.count >= 3 {
                var matched = results.map(\.email)
                if let dr = dateRange {
                    matched = matched.filter { email in
                        guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                        return d >= dr.start && d <= dr.end
                    }
                }
                if matched.count >= 3 {
                    scopedEmails = matched
                    var parts: [String] = []
                    if !specificTerms.isEmpty { parts.append("\"\(specificTerms.joined(separator: ", "))\"") }
                    if let dr = dateRange { parts.append(dr.label) }
                    scopeLabel = "Scoped to \(scopedEmails.count) emails matching \(parts.joined(separator: " in "))\n\n"
                } else {
                    scopedEmails = emails
                }
            } else {
                scopedEmails = emails
            }
        } else {
            scopedEmails = emails
        }

        let isScoped = scopedEmails.count < emails.count

        // MARK: NLP Queries — now run on scoped emails + enriched with RAG content

        if lower.contains("sentiment") || lower.contains("tone") || lower.contains("mood") || lower.contains("feeling") || lower.contains("emotion") {
            let result = EmailNLPEngine.averageSentiment(of: scopedEmails)
            let sentimentResults = EmailNLPEngine.analyzeSentiment(of: scopedEmails)
            let topPositive = sentimentResults.sorted { $0.score > $1.score }.prefix(3)
            let topNegative = sentimentResults.sorted { $0.score < $1.score }.prefix(3)

            var response = scopeLabel + "Sentiment Analysis — \(scopedEmails.count) emails\n\n"
            response += "Overall tone: \(result.label) (score: \(String(format: "%.2f", result.average)))\n\n"
            response += "Breakdown:\n"
            response += "  Positive: \(result.positive) (\(pct(result.positive, scopedEmails.count))%)\n"
            response += "  Neutral: \(result.neutral) (\(pct(result.neutral, scopedEmails.count))%)\n"
            response += "  Negative: \(result.negative) (\(pct(result.negative, scopedEmails.count))%)\n"

            if let firstPositive = topPositive.first, firstPositive.score > 0.1 {
                response += "\nMost positive:\n"
                for r in topPositive {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    response += "  • \(r.email.headers["Subject"] ?? "(No Subject)") — \(from) (\(String(format: "%.2f", r.score)))\n"
                }
            }
            if let firstNegative = topNegative.first, firstNegative.score < -0.1 {
                response += "\nMost negative:\n"
                for r in topNegative {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    response += "  • \(r.email.headers["Subject"] ?? "(No Subject)") — \(from) (\(String(format: "%.2f", r.score)))\n"
                }
            }
            if isScoped { response += "\nCompare: full archive sentiment is \(EmailNLPEngine.averageSentiment(of: emails).label).\n" }
            return response
        }

        if lower.contains("people") || lower.contains("person") || lower.contains("entities") || lower.contains("names") || (lower.contains("who") && lower.contains("mention")) {
            let entities = EmailNLPEngine.extractEntities(from: scopedEmails, limit: 8)
            if entities.isEmpty { return scopeLabel + "No named entities found." }

            var result = scopeLabel + "People & Organizations — \(entities.count) found\n\n"
            for (i, entity) in entities.enumerated() {
                let icon = entity.type == "Person" ? "Person" : entity.type == "Organization" ? "Org" : entity.type
                let nameLower = entity.name.lowercased()
                let mentioning = scopedEmails.filter { email in
                    let all = "\(email.headers["From"] ?? "") \(email.headers["To"] ?? "") \(email.headers["Subject"] ?? "") \(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)".lowercased()
                    return all.contains(nameLower)
                }
                let asSender = mentioning.filter { ($0.headers["From"] ?? "").lowercased().contains(nameLower) }.count
                let asRecipient = mentioning.filter { ($0.headers["To"] ?? "").lowercased().contains(nameLower) }.count
                let sentiment = EmailNLPEngine.averageSentiment(of: mentioning)

                result += "\(i + 1). \(entity.name) [\(icon)] — \(mentioning.count) email\(mentioning.count == 1 ? "" : "s")\n"
                var roles: [String] = []
                if asSender > 0 { roles.append("sent \(asSender)") }
                if asRecipient > 0 { roles.append("received \(asRecipient)") }
                if !roles.isEmpty { result += "   Role: \(roles.joined(separator: ", "))\n" }
                result += "   Tone: \(sentiment.label)\n"

                let subjects = Array(Set(mentioning.prefix(10).compactMap { $0.headers["Subject"] })).prefix(3)
                if !subjects.isEmpty { result += "   Subjects: \(subjects.joined(separator: " | "))\n" }
                result += "\n"
            }
            result += "\nAsk \"tell me more about [name]\" for a full profile."
            return result
        }

        if lower.contains("topic") || lower.contains("keyword") || lower.contains("discuss") || lower.contains("talk about") || lower.contains("about what") {
            let topics = EmailNLPEngine.extractTopics(from: scopedEmails, limit: 10)
            if topics.isEmpty { return scopeLabel + "Not enough text content to extract topics." }

            var result = scopeLabel + "Topic Analysis — \(topics.count) topics across \(scopedEmails.count) emails\n\n"
            for (i, topic) in topics.enumerated() {
                let matching = scopedEmails.filter { email in
                    let text = "\(email.headers["Subject"] ?? "") \(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)".lowercased()
                    return text.contains(topic.word)
                }
                let senderCounts = Dictionary(grouping: matching, by: {
                    $0.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                }).mapValues(\.count).sorted { $0.value > $1.value }
                let sentiment = EmailNLPEngine.averageSentiment(of: matching)

                result += "\(i + 1). \"\(topic.word)\" — \(matching.count) email\(matching.count == 1 ? "" : "s") | Tone: \(sentiment.label)\n"
                if let top = senderCounts.first {
                    result += "   Senders: \(top.key) (\(top.value))"
                    if senderCounts.count > 1 { result += ", \(senderCounts.dropFirst().prefix(2).map { "\($0.key) (\($0.value))" }.joined(separator: ", "))" }
                    result += "\n"
                }
                let subjects = Array(Set(matching.compactMap { $0.headers["Subject"] })).prefix(3)
                if !subjects.isEmpty { result += "   Subjects: \(subjects.joined(separator: " | "))\n" }
                result += "\n"
            }
            return result
        }

        if lower.contains("language") || lower.contains("translate") || lower.contains("foreign") {
            let languages = EmailNLPEngine.detectLanguages(in: scopedEmails)
            if languages.isEmpty { return "Could not detect languages in emails." }
            var result = scopeLabel + "Languages Detected\n\n"
            for lang in languages {
                result += "\(lang.language): \(lang.count) email\(lang.count == 1 ? "" : "s") (\(String(format: "%.0f", lang.percentage))%)\n"
            }
            return result
        }

        if lower.contains("contact insight") || lower.contains("contact analysis") || (lower.contains("who") && lower.contains("positive")) || (lower.contains("who") && lower.contains("negative")) {
            let insights = EmailNLPEngine.contactInsights(from: scopedEmails, limit: 8)
            if insights.isEmpty { return "No contact data to analyze." }
            var result = scopeLabel + "Contact Insights\n\n"
            for (i, c) in insights.enumerated() {
                let name = c.address.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? c.address
                result += "\(i + 1). \(name)\n   \(c.emailCount) emails — Tone: \(c.sentimentLabel) (\(String(format: "%.2f", c.avgSentiment)))\n\n"
            }
            return result
        }

        // MARK: Data Queries

        if lower.contains("how many") && (lower.contains("sent") || lower.contains("send")) {
            let count = scopedEmails.filter { $0.messageType == "sent" }.count
            var result = scopeLabel + "You sent \(count) email\(count == 1 ? "" : "s") out of \(scopedEmails.count) total."
            if isScoped { result += " (full archive: \(emails.filter { $0.messageType == "sent" }.count) sent)" }
            return result
        }

        if lower.contains("how many") && lower.contains("received") {
            let count = scopedEmails.filter { $0.messageType == "received" }.count
            var result = scopeLabel + "You received \(count) email\(count == 1 ? "" : "s") out of \(scopedEmails.count) total."
            if isScoped { result += " (full archive: \(emails.filter { $0.messageType == "received" }.count) received)" }
            return result
        }

        if lower.contains("who") && (lower.contains("most") || lower.contains("frequent") || lower.contains("contacted")) {
            var senderCounts: [String: Int] = [:]
            var recipientCounts: [String: Int] = [:]
            for email in scopedEmails {
                if let from = email.headers["From"] { senderCounts[from, default: 0] += 1 }
                if let to = email.headers["To"] {
                    for addr in to.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                        recipientCounts[addr, default: 0] += 1
                    }
                }
            }

            let topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(5)
            let topRecipients = recipientCounts.sorted { $0.value > $1.value }.prefix(5)

            var result = scopeLabel + "Contact Frequency Analysis\n\n"
            result += "Who contacted you most:\n"
            for (i, sender) in topSenders.enumerated() {
                let name = sender.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? sender.key
                let senderEmails = scopedEmails.filter { $0.headers["From"] == sender.key }
                let sentiment = EmailNLPEngine.averageSentiment(of: senderEmails)
                let subjects = Array(Set(senderEmails.compactMap { $0.headers["Subject"] })).prefix(3)

                result += "\(i + 1). \(name) — \(sender.value) email\(sender.value == 1 ? "" : "s") | Tone: \(sentiment.label)\n"
                if !subjects.isEmpty { result += "   Subjects: \(subjects.joined(separator: " | "))\n" }
            }

            result += "\nWho you emailed most:\n"
            for (i, recipient) in topRecipients.enumerated() {
                let name = recipient.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? recipient.key
                result += "\(i + 1). \(name) — \(recipient.value) email\(recipient.value == 1 ? "" : "s")\n"
            }

            result += "\nAsk \"tell me more about [name]\" for a full profile."
            return result
        }

        if lower.contains("subject") && lower.contains("common") {
            let subjects = Dictionary(grouping: scopedEmails.compactMap { $0.headers["Subject"] }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .prefix(5)
            if subjects.isEmpty { return "No subject data found." }
            var result = scopeLabel + "Top Subjects\n\n"
            for (i, subject) in subjects.enumerated() {
                result += "\(i + 1). \(subject.key) (\(subject.value))\n"
            }
            return result
        }

        if lower.contains("date") && (lower.contains("range") || lower.contains("when")) {
            let dates = scopedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .long
                return scopeLabel + "Date range: \(formatter.string(from: first)) to \(formatter.string(from: last))"
            }
            return "No date information found."
        }

        if lower.contains("reply") || lower.contains("statistic") {
            let sent = scopedEmails.filter { $0.messageType == "sent" }.count
            let received = scopedEmails.filter { $0.messageType == "received" }.count
            let ratio = received > 0 ? Double(sent) / Double(received) : 0
            return scopeLabel + "Reply Statistics\n\nSent: \(sent)\nReceived: \(received)\nRatio: \(String(format: "%.2f", ratio))"
        }

        if lower.contains("attachment") {
            let total = scopedEmails.reduce(0) { $0 + $1.attachments.count }
            let withAttachments = scopedEmails.filter { !$0.attachments.isEmpty }.count
            var result = scopeLabel + "Attachments: \(total) total across \(withAttachments) email\(withAttachments == 1 ? "" : "s").\n\n"
            var typeCounts: [String: Int] = [:]
            for email in scopedEmails {
                for att in email.attachments {
                    let ext = (att.filename as NSString).pathExtension.lowercased()
                    typeCounts[ext.isEmpty ? "unknown" : ext, default: 0] += 1
                }
            }
            if !typeCounts.isEmpty {
                result += "By type:\n"
                for (ext, count) in typeCounts.sorted(by: { $0.value > $1.value }).prefix(8) {
                    result += "  .\(ext): \(count)\n"
                }
            }
            return result
        }

        if lower.contains("phishing") || lower.contains("scam") || lower.contains("suspicious") || lower.contains("spam") || lower.contains("fraud") {
            let flags = EmailNLPEngine.detectPhishing(in: scopedEmails)
            if flags.isEmpty {
                return scopeLabel + "No suspicious emails detected. All \(scopedEmails.count) emails appear safe."
            }
            var result = scopeLabel + "Phishing/Scam Scan\n\n"
            result += "Found \(flags.count) suspicious email\(flags.count == 1 ? "" : "s"):\n\n"
            let highRisk = flags.filter { $0.riskLevel == .high }
            let medRisk = flags.filter { $0.riskLevel == .medium }
            let lowRisk = flags.filter { $0.riskLevel == .low }
            result += "High Risk: \(highRisk.count) | Medium: \(medRisk.count) | Low: \(lowRisk.count)\n\n"
            for (i, flag) in flags.prefix(8).enumerated() {
                result += "\(i + 1). [\(flag.riskLevel.rawValue)] \(flag.email.headers["Subject"] ?? "(No Subject)")\n"
                result += "   From: \(flag.email.headers["From"] ?? "?")\n"
                for reason in flag.reasons.prefix(3) { result += "   ⚠ \(reason)\n" }
                result += "\n"
            }
            return result
        }

        if lower.contains("classify") || lower.contains("categorize") || lower.contains("category") || lower.contains("categories") || lower.contains("type of email") {
            let counts = EmailNLPEngine.classifyAll(scopedEmails)
            var result = scopeLabel + "Email Classification\n\n"
            for cat in EmailNLPEngine.EmailCategory.allCases {
                let count = counts[cat] ?? 0
                if count > 0 {
                    result += "\(cat.rawValue): \(count) (\(pct(count, scopedEmails.count))%)\n"
                }
            }
            return result
        }

        if lower.contains("pii") || lower.contains("personal data") || lower.contains("gdpr") || lower.contains("compliance") || lower.contains("sensitive data") || lower.contains("privacy") {
            let summary = EmailNLPEngine.piiSummary(in: scopedEmails)
            if summary.isEmpty { return scopeLabel + "No PII detected in \(scopedEmails.count) emails." }
            var result = scopeLabel + "PII / Sensitive Data Scan\n\n"
            for type in EmailNLPEngine.PIIType.allCases {
                let count = summary[type] ?? 0
                if count > 0 { result += "\(type.rawValue): \(count) instance\(count == 1 ? "" : "s")\n" }
            }
            return result
        }

        if lower.contains("priority") || lower.contains("important") || lower.contains("urgent") || lower.contains("missed") || lower.contains("action item") {
            let results = EmailNLPEngine.scoreAllPriorities(scopedEmails)
            let high = results.filter { $0.level == .high }
            let medium = results.filter { $0.level == .medium }

            var result = scopeLabel + "Priority Analysis\n\n"
            result += "High: \(high.count) | Medium: \(medium.count) | Low: \(results.count - high.count - medium.count)\n\n"
            if !high.isEmpty {
                result += "High Priority:\n"
                for (i, r) in high.prefix(5).enumerated() {
                    let sentiment = EmailNLPEngine.analyzeSentiment(of: [r.email]).first
                    result += "\(i + 1). \(r.email.headers["Subject"] ?? "(No Subject)")\n"
                    result += "   From: \(r.email.headers["From"] ?? "?")"
                    if let s = sentiment { result += " | Tone: \(s.label)" }
                    result += "\n   Reasons: \(r.reasons.joined(separator: ", "))\n\n"
                }
            }
            if !medium.isEmpty && high.count < 5 {
                result += "Medium Priority:\n"
                for (i, r) in medium.prefix(3).enumerated() {
                    result += "\(i + 1). \(r.email.headers["Subject"] ?? "(No Subject)")\n"
                    result += "   Reasons: \(r.reasons.joined(separator: ", "))\n\n"
                }
            }
            return result
        }

        if lower.contains("thread sentiment") || lower.contains("conversation sentiment") || lower.contains("sentiment trend") || lower.contains("tone trend") || lower.contains("mood trend") {
            let threads = ThreadGrouper.group(scopedEmails)
            let multiMessage = threads.filter { $0.count > 1 }.sorted { $0.count > $1.count }
            if multiMessage.isEmpty { return scopeLabel + "No conversation threads with multiple messages to analyze sentiment trends." }
            var result = scopeLabel + "Thread Sentiment Trends\n\n"
            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .short
            dateFmt.timeStyle = .short
            for (i, thread) in multiMessage.prefix(5).enumerated() {
                let trend = EmailNLPEngine.threadSentimentTrend(thread.allEmails)
                result += "\(i + 1). \(trend.subject)\n"
                result += "   Participants: \(trend.participants.joined(separator: ", "))\n"
                result += "   Overall trend: \(trend.overallTrend)\n"
                for point in trend.points {
                    let label = point.sentiment > 0.1 ? "+" : point.sentiment < -0.1 ? "-" : "~"
                    result += "   [\(label)] \(dateFmt.string(from: point.date)) — \(point.sender): \(String(point.snippet.prefix(60)))...\n"
                }
                result += "\n"
            }
            return result
        }

        if lower.contains("summarize thread") || lower.contains("thread summary") || lower.contains("conversation summary") || (lower.contains("summarize") && lower.contains("thread")) {
            let threads = ThreadGrouper.group(scopedEmails)
            let multiMessage = threads.filter { $0.count > 1 }
            if multiMessage.isEmpty { return scopeLabel + "No conversation threads with multiple messages found." }
            var result = scopeLabel + "Thread Summaries\n\n"
            for (i, thread) in multiMessage.prefix(5).enumerated() {
                let summary = EmailNLPEngine.summarizeThread(thread.allEmails)
                let trend = EmailNLPEngine.threadSentimentTrend(thread.allEmails)
                result += "\(i + 1). \(summary)"
                result += "   Sentiment trend: \(trend.overallTrend)\n"
                result += String(repeating: "-", count: 40) + "\n\n"
            }
            return result
        }

        if lower.contains("cleanup") || lower.contains("storage") || lower.contains("disk") || lower.contains("space") || lower.contains("biggest") {
            let totalSize = scopedEmails.reduce(0) { $0 + $1.rawSource.utf8.count }
            let totalMB = Double(totalSize) / (1024.0 * 1024.0)
            var senderSizes: [String: (count: Int, size: Int)] = [:]
            for email in scopedEmails {
                let sender = email.headers["From"] ?? "Unknown"
                var entry = senderSizes[sender, default: (count: 0, size: 0)]
                entry.count += 1
                entry.size += email.rawSource.utf8.count
                senderSizes[sender] = entry
            }
            let topSenders = senderSizes.sorted { $0.value.size > $1.value.size }.prefix(8)
            var result = scopeLabel + "Storage Analysis\n\n"
            result += "Total: \(String(format: "%.1f", totalMB)) MB across \(scopedEmails.count) emails\n\n"
            for (i, entry) in topSenders.enumerated() {
                let mb = Double(entry.value.size) / (1024.0 * 1024.0)
                result += "\(i + 1). \(entry.key)\n   \(entry.value.count) emails, \(String(format: "%.1f", mb)) MB\n\n"
            }
            return result
        }

        if lower.contains("contact profile") || lower.contains("who contacts") || lower.contains("relationship") || lower.contains("communication") {
            let insights = EmailNLPEngine.contactInsights(from: scopedEmails, limit: 8)
            if insights.isEmpty { return "No contact data available." }
            var result = scopeLabel + "Contact Profiles — \(insights.count) contacts\n\n"
            for (i, c) in insights.enumerated() {
                let addrPart = c.address.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) ?? c.address
                let name = c.address.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? c.address
                let contactEmails = scopedEmails.filter { ($0.headers["From"] ?? "").contains(addrPart) || ($0.headers["To"] ?? "").contains(addrPart) }
                let fromMe = contactEmails.filter { $0.messageType == "sent" }.count
                let toMe = contactEmails.filter { $0.messageType == "received" }.count
                result += "\(i + 1). \(name)\n   \(contactEmails.count) emails (sent: \(fromMe), received: \(toMe)) | Tone: \(c.sentimentLabel)\n\n"
            }
            result += "\nAsk \"tell me more about [name]\" for a deep dive."
            return result
        }

        if lower.contains("summary") || lower.contains("overview") || lower.contains("analyze") || lower.contains("full summary") {
            let sent = scopedEmails.filter { $0.messageType == "sent" }.count
            let received = scopedEmails.filter { $0.messageType == "received" }.count
            let sentiment = EmailNLPEngine.averageSentiment(of: scopedEmails)
            let topics = EmailNLPEngine.extractTopics(from: scopedEmails, limit: 8)
            let languages = EmailNLPEngine.detectLanguages(in: scopedEmails)
            let classification = EmailNLPEngine.classifyAll(scopedEmails)
            let entities = EmailNLPEngine.extractEntities(from: scopedEmails, limit: 5)
            let dates = scopedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            let totalSize = scopedEmails.reduce(0) { $0 + $1.rawSource.utf8.count }
            let sizeMB = Double(totalSize) / (1024.0 * 1024.0)
            let attachmentCount = scopedEmails.reduce(0) { $0 + $1.attachments.count }

            var result = scopeLabel + "Email Archive Summary\n\n"
            result += "Volume: \(scopedEmails.count) emails (\(sent) sent, \(received) received)\n"
            result += "Size: \(String(format: "%.1f", sizeMB)) MB\n"
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                result += "Period: \(formatter.string(from: first)) — \(formatter.string(from: last))\n"
            }
            result += "Language: \(languages.first?.language ?? "Unknown")\n"
            result += "Attachments: \(attachmentCount)\n"
            result += "\nSentiment: \(sentiment.label) (score: \(String(format: "%.2f", sentiment.average)))\n"
            result += "  Positive: \(sentiment.positive) | Neutral: \(sentiment.neutral) | Negative: \(sentiment.negative)\n"

            let catStrings = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> String? in
                guard let count = classification[cat], count > 0 else { return nil }
                return "  \(cat.rawValue): \(count) (\(pct(count, scopedEmails.count))%)"
            }
            if !catStrings.isEmpty { result += "\nCategories:\n" + catStrings.joined(separator: "\n") + "\n" }
            if !topics.isEmpty { result += "\nTopics: \(topics.map(\.word).joined(separator: ", "))\n" }
            if !entities.isEmpty { result += "\nPeople/Orgs: \(entities.map(\.name).joined(separator: ", "))\n" }

            if isScoped { result += "\nThis analysis covers \(scopedEmails.count) of \(emails.count) total emails." }
            return result
        }

        if lower.contains("thread") || lower.contains("conversation") {
            let threads = ThreadGrouper.group(scopedEmails)
            let multiMessage = threads.filter { $0.count > 1 }.sorted { $0.count > $1.count }
            if multiMessage.isEmpty { return scopeLabel + "No conversation threads found." }
            var result = scopeLabel + "Conversation Threads — \(threads.count) total (\(multiMessage.count) with replies)\n\n"
            for (i, thread) in multiMessage.prefix(8).enumerated() {
                let sentiment = EmailNLPEngine.averageSentiment(of: thread.allEmails)
                let trend = EmailNLPEngine.threadSentimentTrend(thread.allEmails)
                let participants = trend.participants.prefix(3).joined(separator: ", ")
                result += "\(i + 1). \(thread.subject)\n"
                result += "   \(thread.count) messages — Tone: \(sentiment.label) (trend: \(trend.overallTrend))\n"
                result += "   Participants: \(participants)\n\n"
            }
            result += "Ask \"summarize thread\" for detailed summaries or \"thread sentiment\" for sentiment trends."
            return result
        }

        if lower == "help" || lower == "?" || lower.hasPrefix("what can you") || lower.hasPrefix("what do you") {
            return """
            Ask me anything about your emails in natural language! Examples:

            • "What did Michael say about the project?"
            • "Find emails about meetings last month"
            • "When was the last email from Priya?"
            • "How many emails mention shipping?"
            • "Show me emails from last week"
            • "Tell me more about John"
            • "Give me a full summary"
            • "What's the sentiment of my emails?"
            • "Scan for phishing or scams"
            • "Show me high priority emails"
            • "Show me thread sentiment trends"
            • "Summarize the conversation threads"

            I understand dates (last week, January, this month), fuzzy names, \
            follow-up questions, and related concepts (meeting → conference, call). \
            For the best experience, enable Apple Intelligence in the toggle above.
            """
        }

        // "Tell me more about [name]" — deep contact profile
        let profilePrefixes = ["tell me more about", "more about", "who is", "profile of", "details about", "info about"]
        for prefix in profilePrefixes {
            if lower.hasPrefix(prefix) {
                let nameStart = lower.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !nameStart.isEmpty {
                    let contactEmails = EmailNLPEngine.fuzzyMatchContacts(name: nameStart, in: emails)
                    if !contactEmails.isEmpty {
                        return buildContactProfile(name: nameStart, emails: contactEmails, allEmails: emails)
                    }
                }
                break
            }
        }

        // Pronoun-based contact lookup from carried context
        let pronounPatterns = ["what did they", "what else did they", "what did he", "what did she",
                               "show me their", "show their", "their emails", "his emails", "her emails",
                               "more from them", "more from him", "more from her", "emails from them",
                               "what about them", "what about him", "what about her"]
        if pronounPatterns.contains(where: { lower.contains($0) }), let name = carriedNames.first {
            let contactEmails = EmailNLPEngine.fuzzyMatchContacts(name: name, in: emails)
            if !contactEmails.isEmpty {
                if lower.contains("more") || lower.contains("profile") || lower.contains("detail") {
                    return buildContactProfile(name: name, emails: contactEmails, allEmails: emails)
                }
                let results = contactEmails.prefix(15).map {
                    EmailNLPEngine.SearchResult(email: $0, score: 1.0, matchContext: "")
                }
                return EmailNLPEngine.synthesizeAnswer(query: "emails from \(name)", terms: [name], results: Array(results), allEmails: emails, dateRange: nil)
            }
        }

        // RAG: extract terms, search with semantic expansion (dateRange already parsed above)
        var searchTerms = EmailNLPEngine.extractSearchTerms(from: lower)

        if dateRange != nil {
            let dateNoiseWords: Set<String> = [
                "january", "february", "march", "april", "may", "june",
                "july", "august", "september", "october", "november", "december",
                "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
                "last", "week", "month", "year", "yesterday", "today", "tomorrow",
                "2020", "2021", "2022", "2023", "2024", "2025", "2026", "2027",
            ]
            searchTerms = searchTerms.filter { !dateNoiseWords.contains($0.lowercased()) }
        }

        // Merge carried context into search terms when query alone is too vague
        if searchTerms.isEmpty && !carriedNames.isEmpty {
            searchTerms = carriedNames
        }
        if searchTerms.isEmpty && !carriedTopics.isEmpty {
            searchTerms = carriedTopics
        }

        // Date-only queries (no search terms, just time filter)
        if searchTerms.isEmpty && dateRange != nil {
            let results = EmailNLPEngine.searchWithDateFilter(terms: [], in: emails, dateRange: dateRange, limit: 15)
            if !results.isEmpty {
                return EmailNLPEngine.synthesizeAnswer(query: lower, terms: [], results: results, allEmails: emails, dateRange: dateRange)
            }
            return "No emails found in \(dateRange!.label)."
        }

        if !searchTerms.isEmpty {
            let results = EmailNLPEngine.searchWithDateFilter(terms: searchTerms, in: emails, dateRange: dateRange, limit: 15)
            if !results.isEmpty {
                return EmailNLPEngine.synthesizeAnswer(query: lower, terms: searchTerms, results: results, allEmails: emails, dateRange: dateRange)
            }

            // Fallback: try carried names/topics if direct terms found nothing
            if !carriedNames.isEmpty && carriedNames != searchTerms {
                let fallbackTerms = searchTerms + carriedNames
                let fallbackResults = EmailNLPEngine.searchWithDateFilter(terms: fallbackTerms, in: emails, dateRange: dateRange, limit: 15)
                if !fallbackResults.isEmpty {
                    return EmailNLPEngine.synthesizeAnswer(query: lower, terms: fallbackTerms, results: fallbackResults, allEmails: emails, dateRange: dateRange)
                }
            }
        }

        if EmailNLPEngine.isEmailRelated(lower, terms: searchTerms, emails: emails) {
            var suggestion = "I searched through all \(emails.count) emails but couldn't find content matching your question."
            if dateRange != nil {
                suggestion += " No emails matched in \(dateRange!.label)."
            }
            suggestion += " Try rephrasing with specific names, subjects, or keywords from your emails."
            return suggestion
        }

        return "Sorry, I can't answer that — it doesn't appear to be related to your email data. I can answer any question about your \(emails.count) emails: people, topics, dates, content, sentiment, and more. Try asking something about your emails!"
    }

    // MARK: - Conversation Context Resolution

    private struct ResolvedContext {
        let query: String
        let names: [String]
        let topics: [String]
    }

    private static func resolveConversationContext(query: String, priorContext: String) -> ResolvedContext {
        guard !priorContext.isEmpty else {
            return ResolvedContext(query: query, names: [], topics: [])
        }

        var resolvedQuery = query
        let priorLower = priorContext.lowercased()

        // Extract names mentioned in prior conversation
        let nameTagger = NLTagger(tagSchemes: [.nameType])
        var priorNames: [String] = []
        nameTagger.string = priorContext
        let monthWords: Set<String> = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
                                         "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"]
        nameTagger.enumerateTags(in: priorContext.startIndex..<priorContext.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, tokenRange in
            if tag == .personalName || tag == .organizationName {
                let name = String(priorContext[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count >= 3 && !monthWords.contains(name.lowercased()) && !priorNames.contains(where: { $0.lowercased() == name.lowercased() }) {
                    priorNames.append(name)
                }
            }
            return true
        }

        // Extract names from "From:" and "Contact Profile:" lines in prior answers
        let fromPattern = try? NSRegularExpression(pattern: #"(?:From|Profile):\s*([A-Z][a-z]+(?: [A-Z][a-z]+)*)"#)
        if let fromPattern {
            let matches = fromPattern.matches(in: priorContext, range: NSRange(priorContext.startIndex..., in: priorContext))
            for match in matches {
                if let range = Range(match.range(at: 1), in: priorContext) {
                    let name = String(priorContext[range])
                    if !priorNames.contains(where: { $0.lowercased() == name.lowercased() }) {
                        priorNames.append(name)
                    }
                }
            }
        }

        // Extract topics from prior context
        var priorTopics: [String] = []
        let topicPatterns = [
            #"(?:about|regarding|topic|subject)[\s:]+\"?([a-z ]{3,30})\"?"#,
            #"Re:\s*(.+?)[\n\"]"#,
        ]
        for pattern in topicPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: priorContext, range: NSRange(priorContext.startIndex..., in: priorContext))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: priorContext) {
                        let topic = String(priorContext[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if topic.count >= 3 && !priorTopics.contains(topic) {
                            priorTopics.append(topic)
                        }
                    }
                }
            }
        }

        let isFollowUp = query.contains("more") || query.contains("also") || query.contains("else") ||
            query.contains("what about") || query.contains("and") || query.contains("too") ||
            query.contains("another") || query.contains("other") || query.contains("again") ||
            query.contains("continue") || query.contains("go on") || query.count < 20

        let hasPronouns = query.contains(" he ") || query.contains(" she ") || query.contains(" they ") ||
            query.contains(" him ") || query.contains(" her ") || query.contains(" them ") ||
            query.contains(" his ") || query.contains(" their ") || query.contains("that person") ||
            query.contains("that sender") || query.contains("the sender") || query.contains("this person") ||
            query.hasPrefix("he ") || query.hasPrefix("she ") || query.hasPrefix("they ") ||
            query.hasPrefix("him ") || query.hasPrefix("her ") || query.hasPrefix("them ")

        // Resolve pronouns to the most recent name from conversation
        if hasPronouns, let recentName = priorNames.last {
            let pronouns = [" he ", " she ", " they ", " him ", " her ", " them ",
                            " his ", " their ", "that person", "that sender", "the sender", "this person"]
            for pronoun in pronouns {
                if resolvedQuery.contains(pronoun) {
                    resolvedQuery = resolvedQuery.replacingOccurrences(of: pronoun, with: " \(recentName.lowercased()) ")
                }
            }
            if resolvedQuery.hasPrefix("he ") || resolvedQuery.hasPrefix("she ") || resolvedQuery.hasPrefix("they ") {
                if let spaceIndex = resolvedQuery.firstIndex(of: " ") {
                    resolvedQuery = recentName.lowercased() + " " + String(resolvedQuery[resolvedQuery.index(after: spaceIndex)...])
                }
            }
        }

        // Append prior topic keywords for vague follow-ups
        if isFollowUp && !hasPronouns {
            if priorLower.contains("sentiment") { resolvedQuery += " sentiment" }
            if priorLower.contains("topic") || priorLower.contains("keyword") { resolvedQuery += " topic" }
            if priorLower.contains("people") || priorLower.contains("entities") { resolvedQuery += " people" }
            if priorLower.contains("language") { resolvedQuery += " language" }
            if priorLower.contains("thread") || priorLower.contains("conversation") { resolvedQuery += " thread" }
            if priorLower.contains("phishing") || priorLower.contains("scam") { resolvedQuery += " phishing" }
            if priorLower.contains("priority") || priorLower.contains("urgent") { resolvedQuery += " priority" }
            if priorLower.contains("attachment") { resolvedQuery += " attachment" }
            if priorLower.contains("categor") { resolvedQuery += " categorize" }
        }

        return ResolvedContext(query: resolvedQuery, names: priorNames, topics: priorTopics)
    }

    // MARK: - Contact Profile Builder

    private static func buildContactProfile(name: String, emails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail]) -> String {
        let fromMe = emails.filter { $0.messageType == "sent" }
        let toMe = emails.filter { $0.messageType == "received" }
        let threads = emails.filter { $0.inReplyTo != nil }
        let subjects = Array(Set(emails.compactMap { $0.headers["Subject"] }))
        let sentiment = EmailNLPEngine.averageSentiment(of: emails)

        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium

        let displayName: String
        if let firstEmail = emails.first(where: { ($0.headers["From"] ?? "").lowercased().contains(name.lowercased()) }),
           let fromHeader = firstEmail.headers["From"] {
            displayName = fromHeader.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? name.capitalized
        } else {
            displayName = name.capitalized
        }

        var result = "Contact Profile: \(displayName)\n\n"
        result += "Total emails: \(emails.count) (you sent: \(fromMe.count), received: \(toMe.count))\n"
        if !threads.isEmpty { result += "Conversation threads: \(threads.count)\n" }
        result += "Tone: \(sentiment.label) (\(String(format: "%.2f", sentiment.average)))\n"
        if let first = dates.first, let last = dates.last {
            result += "Active: \(dateFmt.string(from: first)) — \(dateFmt.string(from: last))\n"
        }

        if !subjects.isEmpty {
            result += "\nTopics discussed (\(subjects.count)):\n"
            for subj in subjects.prefix(8) {
                result += "  • \(subj)\n"
            }
            if subjects.count > 8 { result += "  ...and \(subjects.count - 8) more\n" }
        }

        result += "\nRecent emails:\n"
        let sortedByDate = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) >
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }
        for (i, email) in sortedByDate.prefix(6).enumerated() {
            let date = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }
            let dateStr = date.map { dateFmt.string(from: $0) } ?? ""
            let dir = email.messageType == "sent" ? "→" : "←"
            result += "  \(i + 1). \(dir) \(email.headers["Subject"] ?? "(No Subject)") — \(dateStr)\n"
        }
        if emails.count > 6 { result += "  ...and \(emails.count - 6) more\n" }

        let otherContacts = Set(emails.compactMap { $0.headers["To"] }).union(Set(emails.compactMap { $0.headers["Cc"] }))
        let filteredContacts = otherContacts.filter { !$0.lowercased().contains(name.lowercased()) }
        if !filteredContacts.isEmpty {
            result += "\nAlso in conversations with: \(filteredContacts.prefix(5).joined(separator: ", "))\n"
        }

        return result
    }

    private static func pct(_ count: Int, _ total: Int) -> String {
        String(format: "%.0f", Double(count) / Double(max(total, 1)) * 100)
    }

    // MARK: - Conversation Persistence

    private struct SavedTurn: Codable {
        let query: String
        let answer: String
    }

    private static var conversationURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai_conversation.json")
    }

    private func saveConversation() {
        guard !conversationHistory.isEmpty else { return }
        let turns = conversationHistory.suffix(20).map { SavedTurn(query: $0.query, answer: $0.answer) }
        if let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: Self.conversationURL, options: .atomic)
        }
    }

    private func loadConversation() {
        guard conversationHistory.isEmpty,
              let data = try? Data(contentsOf: Self.conversationURL),
              let turns = try? JSONDecoder().decode([SavedTurn].self, from: data) else { return }
        conversationHistory = turns.map { (query: $0.query, answer: $0.answer) }
    }

    static func clearSavedConversation() {
        try? FileManager.default.removeItem(at: conversationURL)
    }

    // MARK: - Export

    private func exportConversation() {
        guard !conversationHistory.isEmpty else { return }

        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .long
        dateFmt.timeStyle = .short

        var markdown = "# mailin — AI Email Analysis Report\n\n"
        markdown += "**Generated:** \(dateFmt.string(from: Date()))\n"
        markdown += "**Emails analyzed:** \(emails.count)\n"
        markdown += "**Engine:** \(selectedEngine.rawValue)\n\n---\n\n"

        for (i, turn) in conversationHistory.enumerated() {
            markdown += "### Q\(i + 1): \(turn.query)\n\n"
            markdown += "\(turn.answer)\n\n---\n\n"
        }

        markdown += "*Report generated by mailin — privacy-first email archive analyzer*\n"

        let panel = NSSavePanel()
        panel.title = "Export AI Report"
        panel.nameFieldStringValue = "mailin-report-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

#Preview {
    AIAssistantView(emails: [])
}
