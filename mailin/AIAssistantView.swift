import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import NaturalLanguage
import UniformTypeIdentifiers

struct AIAssistantView: View {
    let allEmails: [MBOXParser.RawEmail]
    let filteredEmails: [MBOXParser.RawEmail]
    let selectedEmails: [MBOXParser.RawEmail]
    var searchContext: String = ""

    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    @State private var prompt = ""
    @State private var isProcessing = false
    @State private var conversationHistory: [(query: String, answer: String, timestamp: Date)] = []
    @State private var selectedEngine: AIEngine = .nlp
    @State private var emailScope: EmailScope = .filtered
    @State private var currentTask: Task<Void, Never>?
    @State private var streamingQuery = ""
    @State private var streamingAnswer = ""
    @State private var freeQueryCount: Int = 0
    @State private var showUpgradePaywall = false
    @State private var priorRetrievedEmailIDs: Set<UUID> = []
    @EnvironmentObject private var storeManager: StoreManager

    static let freeQueryLimit = 3

    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif

    @Environment(\.dismiss) private var dismiss

    private enum AIEngine: String, CaseIterable {
        case appleAI = "Apple AI"
        case nlp = "NLP"
    }

    enum EmailScope: String, CaseIterable {
        case all = "All Emails"
        case filtered = "Filtered"
        case selected = "Selected"
    }

    private var emails: [MBOXParser.RawEmail] {
        switch emailScope {
        case .all: return allEmails
        case .filtered: return filteredEmails.isEmpty ? allEmails : filteredEmails
        case .selected: return selectedEmails.isEmpty ? filteredEmails : selectedEmails
        }
    }


    private var foundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
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
        if #available(macOS 26, iOS 26, *) {
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
                .frame(maxHeight: .infinity)
            inputArea
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 700, minHeight: 500, idealHeight: 650)
        #endif
        .background(AppColors.backgroundTertiary)
        .onAppear {
            if foundationModelAvailable {
                selectedEngine = .appleAI
            } else {
                selectedEngine = .nlp
            }
            if !selectedEmails.isEmpty {
                emailScope = .selected
            }
            loadConversation()
        }
        .onDisappear {
            currentTask?.cancel()
            currentTask = nil
            saveConversation()
        }
        .sheet(isPresented: $showUpgradePaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
    }

    // MARK: - LLM Status Banners

    private var llmNotEnabledBanner: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "sparkles")
                .font(Typography.title3)
                .adaptiveIconGradient(colors: [.blue, .purple])
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
                #if os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.general") {
                    PlatformURLOpener.open(url)
                }
                #else
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    PlatformURLOpener.open(url)
                }
                #endif
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
        VStack(spacing: 0) {
            HStack(spacing: Spacing.small) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .adaptiveIconGradient(colors: [.blue, .purple])

                VStack(alignment: .leading, spacing: 0) {
                    Text("AI Email Assistant")
                        .font(Typography.headline)
                    Text(engineDescription)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }

                Spacer()

                if !storeManager.isPremium {
                    let remaining = max(0, Self.freeQueryLimit - freeQueryCount)
                    Text("\(remaining)/\(Self.freeQueryLimit) free")
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(remaining > 0 ? AppColors.secondary : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(remaining > 0 ? AppColors.backgroundSecondary : Color.orange.opacity(0.12))
                        .cornerRadius(CornerRadius.round)
                }

                if isProcessing {
                    Button {
                        currentTask?.cancel()
                        currentTask = nil
                        isProcessing = false
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(AppColors.error)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop AI processing")
                }

                Button(action: exportConversation) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(conversationHistory.isEmpty)
                .help("Export conversation")

                Button {
                    conversationHistory.removeAll()
                    Self.clearSavedConversation()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(conversationHistory.isEmpty)
                .help("Clear conversation")

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            .background(AppColors.backgroundPrimary)

            HStack(spacing: Spacing.small) {
                if foundationModelAvailable {
                    Picker("Engine", selection: $selectedEngine) {
                        if foundationModelAvailable {
                            Text("Apple AI").tag(AIEngine.appleAI)
                        }
                        Text("NLP").tag(AIEngine.nlp)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Divider().frame(height: 16)
                }

                Picker("Scope", selection: $emailScope) {
                    Text("All (\(emailCount(for: .all)))").tag(EmailScope.all)
                    Text("Filtered (\(emailCount(for: .filtered)))").tag(EmailScope.filtered)
                    Text("Selected (\(emailCount(for: .selected)))").tag(EmailScope.selected)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()

                Label("\(emails.count) emails", systemImage: "envelope")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall)
            .background(AppColors.backgroundSecondary.opacity(0.4))
        }
    }

    private var engineDescription: String {
        switch selectedEngine {
        case .appleAI: return "On-device Apple Intelligence"
        case .nlp: return "On-device NLP analysis"
        }
    }

    private func emailCount(for scope: EmailScope) -> Int {
        switch scope {
        case .all: return allEmails.count
        case .filtered: return filteredEmails.isEmpty ? allEmails.count : filteredEmails.count
        case .selected: return selectedEmails.count
        }
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
                            chatBubble(query: item.query, answer: item.answer, timestamp: item.timestamp)
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
                .font(.largeTitle)
                .adaptiveIconGradient(colors: [personaManager.selectedPersona.accentColor, personaManager.selectedPersona.accentColor.opacity(0.5)])

            VStack(spacing: Spacing.xSmall) {
                Text(personaAITitle)
                    .font(Typography.title3)
                Text({
                    switch selectedEngine {
                    case .appleAI: return "Powered by Apple Intelligence — 100% on-device"
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

            // Deep AI quick actions (require Apple AI engine)
            if foundationModelAvailable {
                questions.append("[Smart Triage] Prioritize my emails and suggest actions")
                questions.append("[Insights] Generate proactive insights from my inbox")
                questions.append("[Security Brief] Scan for phishing and data exposure risks")
            }

            // Thread narrative (works for any scope with multiple emails)
            if emails.count >= 2 && foundationModelAvailable {
                questions.append("[Thread Story] Narrate this conversation thread")
            }
        }

        questions.append(contentsOf: personaManager.config.sampleAIQueries)

        return Array(questions.prefix(10))
    }

    // MARK: - Chat Bubble

    private static let chatTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private func chatBubble(query: String, answer: String, timestamp: Date? = nil, isStreaming: Bool = false) -> some View {
        VStack(spacing: Spacing.small) {
            // User message
            HStack {
                Spacer(minLength: Spacing.xxLarge)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(query)
                        .font(Typography.body)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .foregroundColor(.white)
                        .background(
                            LinearGradient(colors: [.blue, .blue.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .cornerRadius(CornerRadius.large)
                    if let ts = timestamp {
                        Text(Self.chatTimestampFormatter.string(from: ts))
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary.opacity(0.6))
                    }
                }
                .accessibilityLabel("Your question: \(query)")
            }

            // AI response
            HStack {
                VStack(alignment: .leading, spacing: 2) {
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
                    if let ts = timestamp, !isStreaming {
                        Text(Self.chatTimestampFormatter.string(from: ts))
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary.opacity(0.6))
                    }
                }
                Spacer(minLength: Spacing.xxLarge)
            }
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.small) {
                TextField("Ask a follow-up question...", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .padding(.horizontal, Spacing.medium)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .fill(AppColors.backgroundSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .stroke(Color.blue.opacity(0.4), lineWidth: 1.5)
                    )
                    .onSubmit { askAI() }
                    .accessibilityLabel("Question input")
                    .accessibilityHint("Type a question about your emails, then press Return to send")

                Button(action: askAI) {
                    Group {
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.blue : AppColors.secondary.opacity(0.3))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel(isProcessing ? "Processing query" : "Send question")
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, 12)
            .background(AppColors.backgroundPrimary)
        }
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
        case .nlp:
            if foundationModelAvailable {
                return "Analyzing \(count) email\(suffix) with NLP + Apple Intelligence (on-device)"
            }
            return "Analyzing \(count) email\(suffix) with on-device NLP"
        }
    }

    private var engineHelp: String {
        switch selectedEngine {
        case .appleAI: return "Apple Intelligence — on-device, private"
        case .nlp:
            if foundationModelAvailable {
                return "NLP retrieval + Apple AI synthesis — best of both, fully on-device"
            }
            return "NLP — fast, on-device analysis"
        }
    }

    // MARK: - AI Logic

    private func askAI() {
        let query = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        if !storeManager.isPremium && freeQueryCount >= Self.freeQueryLimit {
            showUpgradePaywall = true
            return
        }

        currentTask?.cancel()
        isProcessing = true
        let currentQuery = query
        prompt = ""

        if !storeManager.isPremium {
            freeQueryCount += 1
        }

        let context = searchContext
        let emailsCopy = emails
        let engine = selectedEngine

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
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date()))
                }
            }

        case .nlp:
            let priorContext = conversationHistory.suffix(3).map { "Q: \($0.query)\nA: \($0.answer)" }.joined(separator: "\n\n")
            let currentPredictions = PredictiveCodingEngine.shared.predictions
            let canUseAppleAI = foundationModelAvailable
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }

                // Step 1: Run NLP for structured analysis (fast, deterministic)
                let nlpResult = await Task.detached(priority: .userInitiated) {
                    AIAssistantView.processNLPQuery(currentQuery, emails: emailsCopy, priorContext: priorContext, predictions: currentPredictions)
                }.value
                guard !Task.isCancelled else { return }

                // Step 2: If Apple AI available + query is open-ended, use agentic RAG pipeline
                var answer: String
                if canUseAppleAI && Self.isOpenEndedQuery(currentQuery) {
                    let priorIDs = priorRetrievedEmailIDs
                    let ragResult = await Task.detached(priority: .userInitiated) {
                        Self.agenticRetrieve(query: currentQuery, emails: emailsCopy, priorContext: priorContext, predictions: currentPredictions, priorRetrievedIDs: priorIDs)
                    }.value

                    priorRetrievedEmailIDs.formUnion(ragResult.retrievedEmails.map(\.id))

                    streamingQuery = currentQuery
                    streamingAnswer = ""
                    answer = await hybridAgenticSynthesis(
                        query: currentQuery,
                        ragResult: ragResult,
                        nlpFallback: nlpResult,
                        allEmailCount: emailsCopy.count
                    )
                    streamingQuery = ""
                    streamingAnswer = ""
                } else {
                    answer = nlpResult
                }

                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date()))
                }
            }
        }
    }

    private struct TimeoutError: Error {}

    private enum SpecialAction {
        case triage, insights, securityBrief, threadStory, general
    }

    private static func detectSpecialAction(_ query: String) -> SpecialAction {
        let q = query.lowercased()
        if q.hasPrefix("[smart triage]") { return .triage }
        if q.hasPrefix("[insights]") { return .insights }
        if q.hasPrefix("[security brief]") { return .securityBrief }
        if q.hasPrefix("[thread story]") { return .threadStory }
        return .general
    }

    private func askFoundationModelStreaming(_ query: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            // Route special quick-action queries to dedicated methods
            let specialAction = Self.detectSpecialAction(query)
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        switch specialAction {
                        case .triage:
                            return try await FoundationModelEngine.triageEmails(self.emails) { partial in
                                self.streamingAnswer = partial
                            }
                        case .insights:
                            return try await FoundationModelEngine.generateInsights(self.emails) { partial in
                                self.streamingAnswer = partial
                            }
                        case .securityBrief:
                            return try await FoundationModelEngine.securityBrief(self.emails) { partial in
                                self.streamingAnswer = partial
                            }
                        case .threadStory:
                            return try await FoundationModelEngine.synthesizeThread(self.emails) { partial in
                                self.streamingAnswer = partial
                            }
                        case .general:
                            return try await FoundationModelEngine.respondStreaming(to: query, emails: self.emails) { partial in
                                self.streamingAnswer = partial
                            }
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
        if #available(macOS 26, iOS 26, *) {
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

    nonisolated static func processNLPQuery(_ query: String, emails: [MBOXParser.RawEmail], priorContext: String = "", predictions: [UUID: Double] = [:]) -> String {
        var lower = query.lowercased()
        let resolved = resolveConversationContext(query: lower, priorContext: priorContext)
        lower = resolved.query
        let carriedNames = resolved.names
        let carriedTopics = resolved.topics

        // MARK: - Complex query decomposition
        // Handle multi-part queries like "urgent emails from John about budget"
        let queryParts = decomposeQuery(lower)
        if !queryParts.sentimentFilter.isEmpty || queryParts.hasPriorityFilter {
            let baseResults = executeDecomposedQuery(queryParts, emails: emails)
            if !baseResults.isEmpty {
                return EmailNLPEngine.synthesizeAnswer(
                    query: lower,
                    terms: queryParts.contentTerms,
                    results: baseResults,
                    allEmails: emails,
                    dateRange: queryParts.dateRange
                )
            }
        }

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

            // Natural language framing
            var response = scopeLabel
            let toneDesc: String
            if result.average > 0.3 { toneDesc = "quite positive" }
            else if result.average > 0.1 { toneDesc = "generally positive" }
            else if result.average > -0.1 { toneDesc = "fairly neutral" }
            else if result.average > -0.3 { toneDesc = "somewhat negative" }
            else { toneDesc = "noticeably negative" }

            response += "Your emails have a **\(toneDesc)** tone overall. "
            let dominantPct = max(result.positive, result.neutral, result.negative)
            let dominantLabel = dominantPct == result.positive ? "positive" : dominantPct == result.negative ? "negative" : "neutral"
            response += "Out of \(scopedEmails.count) emails analyzed, the majority (\(pct(dominantPct, scopedEmails.count))%) are **\(dominantLabel)** in nature"
            if dominantPct != result.positive && result.positive > 0 {
                response += ", with \(pct(result.positive, scopedEmails.count))% being positive"
            }
            if dominantPct != result.negative && result.negative > 0 {
                response += " and \(pct(result.negative, scopedEmails.count))% negative"
            }
            response += ".\n\n"

            if let firstPositive = topPositive.first, firstPositive.score > 0.1 {
                response += "The **most upbeat** exchanges include:\n"
                for r in topPositive {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    response += "- \"\(r.email.headers["Subject"] ?? "(No Subject)")\" from **\(from)** — warm and positive\n"
                }
                response += "\n"
            }
            if let firstNegative = topNegative.first, firstNegative.score < -0.1 {
                response += "On the other hand, these emails carried a **more critical or concerned** tone:\n"
                for r in topNegative {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    response += "- \"\(r.email.headers["Subject"] ?? "(No Subject)")\" from **\(from)**\n"
                }
                response += "\n"
            }
            if isScoped {
                let fullSentiment = EmailNLPEngine.averageSentiment(of: emails)
                response += "For comparison, your full email archive has a **\(fullSentiment.label.lowercased())** tone overall.\n"
            }
            response += "\nYou can ask about specific contacts (e.g., \"what's the tone of emails from John?\") for a deeper look."
            return response
        }

        if lower.contains("people") || lower.contains("person") || lower.contains("entities") || lower.contains("names") || (lower.contains("who") && lower.contains("mention")) {
            let entities = EmailNLPEngine.extractEntities(from: scopedEmails, limit: 8)
            if entities.isEmpty { return scopeLabel + "I couldn't identify any specific people or organizations in these emails. Try asking about a specific name instead." }

            var result = scopeLabel + "Here are the **key people and organizations** mentioned across your emails:\n\n"
            for (i, entity) in entities.enumerated() {
                let typeLabel = entity.type == "Person" ? "person" : entity.type == "Organization" ? "organization" : entity.type.lowercased()
                let nameLower = entity.name.lowercased()
                let mentioning = scopedEmails.filter { email in
                    let all = "\(email.headers["From"] ?? "") \(email.headers["To"] ?? "") \(email.headers["Subject"] ?? "") \(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)".lowercased()
                    return all.contains(nameLower)
                }
                let asSender = mentioning.filter { ($0.headers["From"] ?? "").lowercased().contains(nameLower) }.count
                let asRecipient = mentioning.filter { ($0.headers["To"] ?? "").lowercased().contains(nameLower) }.count
                let sentiment = EmailNLPEngine.averageSentiment(of: mentioning)
                let toneWord = sentiment.average > 0.1 ? "positive" : sentiment.average < -0.1 ? "critical" : "neutral"

                result += "**\(i + 1). \(entity.name)** (\(typeLabel)) — appears in \(mentioning.count) email\(mentioning.count == 1 ? "" : "s")\n"
                var roleDesc: [String] = []
                if asSender > 0 { roleDesc.append("sent \(asSender)") }
                if asRecipient > 0 { roleDesc.append("received \(asRecipient)") }
                if !roleDesc.isEmpty { result += "   \(roleDesc.joined(separator: ", ").capitalized) — tone is generally \(toneWord)\n" }

                let subjects = Array(Set(mentioning.prefix(10).compactMap { $0.headers["Subject"] })).prefix(3)
                if !subjects.isEmpty { result += "   Involved in: \(subjects.joined(separator: ", "))\n" }
                result += "\n"
            }
            result += "Want to know more about someone? Just ask \"tell me more about [name]\" for their full profile."
            return result
        }

        if lower.contains("topic") || lower.contains("keyword") || lower.contains("discuss") || lower.contains("talk about") || lower.contains("about what") {
            let topics = EmailNLPEngine.extractTopics(from: scopedEmails, limit: 10)
            if topics.isEmpty { return scopeLabel + "There isn't enough text content in these emails to identify clear topics. Try asking about a specific subject instead." }

            var result = scopeLabel + "Your emails revolve around **\(topics.count) key themes** across \(scopedEmails.count) emails:\n\n"
            for (i, topic) in topics.enumerated() {
                let matching = scopedEmails.filter { email in
                    let text = "\(email.headers["Subject"] ?? "") \(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)".lowercased()
                    return text.contains(topic.word)
                }
                let senderCounts = Dictionary(grouping: matching, by: {
                    $0.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                }).mapValues(\.count).sorted { $0.value > $1.value }
                let sentiment = EmailNLPEngine.averageSentiment(of: matching)

                // Natural topic description
                let toneWord = sentiment.average > 0.1 ? "positive" : sentiment.average < -0.1 ? "concerned" : "neutral"
                result += "**\(i + 1). \(topic.word.capitalized)** — appears in \(matching.count) email\(matching.count == 1 ? "" : "s") with a \(toneWord) tone\n"

                if let top = senderCounts.first {
                    var senderStr = "Mainly discussed by **\(top.key)**"
                    if senderCounts.count > 1 {
                        let others = senderCounts.dropFirst().prefix(2).map { "**\($0.key)**" }
                        senderStr += ", \(others.joined(separator: ", "))"
                    }
                    result += "   \(senderStr)\n"
                }
                let subjects = Array(Set(matching.compactMap { $0.headers["Subject"] })).prefix(2)
                if !subjects.isEmpty { result += "   Example threads: \(subjects.joined(separator: ", "))\n" }
                result += "\n"
            }
            result += "Ask me about any specific topic (e.g., \"what about \(topics.first?.word ?? "meetings")?\") for more detail."
            return result
        }

        if lower.contains("language") || lower.contains("translate") || lower.contains("foreign") {
            let languages = EmailNLPEngine.detectLanguages(in: scopedEmails)
            if languages.isEmpty { return "I couldn't reliably detect languages in these emails — the content may be too short for accurate detection." }
            var result = scopeLabel
            if languages.count == 1 {
                result += "Your emails are predominantly in **\(languages[0].language)** — virtually all \(languages[0].count) emails are written in this language.\n"
            } else {
                result += "Your emails span **\(languages.count) languages**. Here's the breakdown:\n\n"
                for lang in languages {
                    let bar = String(repeating: "█", count: max(1, Int(lang.percentage / 5)))
                    result += "- **\(lang.language)**: \(lang.count) email\(lang.count == 1 ? "" : "s") (\(String(format: "%.0f", lang.percentage))%) \(bar)\n"
                }
            }
            return result
        }

        if lower.contains("contact insight") || lower.contains("contact analysis") || (lower.contains("who") && lower.contains("positive")) || (lower.contains("who") && lower.contains("negative")) {
            let insights = EmailNLPEngine.contactInsights(from: scopedEmails, limit: 8)
            if insights.isEmpty { return "I don't have enough contact data to provide insights. Try importing more emails or asking about a specific person." }
            var result = scopeLabel + "Here's a look at your **key contacts** and the tone of your exchanges:\n\n"
            for (i, c) in insights.enumerated() {
                let name = c.address.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? c.address
                let toneWord = c.avgSentiment > 0.1 ? "warm and positive" : c.avgSentiment < -0.1 ? "more formal or critical" : "neutral and professional"
                result += "\(i + 1). **\(name)** — \(c.emailCount) email\(c.emailCount == 1 ? "" : "s"), tone is \(toneWord)\n"
            }
            result += "\nAsk \"tell me more about [name]\" for a detailed profile of any contact."
            return result
        }

        // MARK: Data Queries

        if (lower.contains("how many") || lower.contains("how much") || lower.contains("count") || lower.contains("total")) &&
           (lower.contains("email") || lower.contains("mail") || lower.contains("message")) &&
           !lower.contains("sent") && !lower.contains("send") && !lower.contains("received") {
            let sent = scopedEmails.filter { $0.messageType == "sent" }.count
            let received = scopedEmails.filter { $0.messageType == "received" }.count
            let dates = scopedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            let attachmentCount = scopedEmails.reduce(0) { $0 + $1.attachments.count }
            var result = scopeLabel + "You have **\(scopedEmails.count) emails** in total — \(sent) sent and \(received) received."
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                result += " They span from **\(formatter.string(from: first))** to **\(formatter.string(from: last))**."
            }
            if attachmentCount > 0 { result += " There are \(attachmentCount) attachments across these messages." }
            if isScoped { result += "\n\n(Full archive: \(emails.count) emails)" }
            return result
        }

        if lower.contains("how many") && (lower.contains("sent") || lower.contains("send")) {
            let count = scopedEmails.filter { $0.messageType == "sent" }.count
            let pctSent = scopedEmails.count > 0 ? Int(Double(count) / Double(scopedEmails.count) * 100) : 0
            var result = scopeLabel + "You sent **\(count) email\(count == 1 ? "" : "s")** out of \(scopedEmails.count) total — that's about \(pctSent)% of your archive."
            if isScoped { result += " Across your full archive, you've sent \(emails.filter { $0.messageType == "sent" }.count) emails." }
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

            var result = scopeLabel
            if let topSender = topSenders.first {
                let topName = topSender.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? topSender.key
                result += "Your most frequent contact is **\(topName)**, who sent you **\(topSender.value) emails**. "
                if topSenders.count > 1, let second = topSenders.dropFirst().first {
                    let secondName = second.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    result += "**\(secondName)** comes in second"
                    if topSenders.count > 2 {
                        result += ", followed by others"
                    }
                    result += "."
                }
                result += "\n\n"
            }

            result += "**People who email you most:**\n\n"
            for (i, sender) in topSenders.enumerated() {
                let name = sender.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? sender.key
                let senderEmails = scopedEmails.filter { $0.headers["From"] == sender.key }
                let sentiment = EmailNLPEngine.averageSentiment(of: senderEmails)
                let subjects = Array(Set(senderEmails.compactMap { $0.headers["Subject"] })).prefix(3)

                let toneWord = sentiment.average > 0.1 ? "positive" : sentiment.average < -0.1 ? "critical" : "neutral"
                result += "\(i + 1). **\(name)** — \(sender.value) email\(sender.value == 1 ? "" : "s"), generally \(toneWord) in tone\n"
                if !subjects.isEmpty { result += "   Topics: \(subjects.joined(separator: ", "))\n" }
            }

            result += "\n**People you email most:**\n\n"
            for (i, recipient) in topRecipients.enumerated() {
                let name = recipient.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? recipient.key
                result += "\(i + 1). **\(name)** — \(recipient.value) email\(recipient.value == 1 ? "" : "s")\n"
            }

            result += "\nWant to dig deeper? Ask \"tell me more about [name]\" for a full profile of any contact."
            return result
        }

        if lower.contains("subject") && lower.contains("common") {
            let subjects = Dictionary(grouping: scopedEmails.compactMap { $0.headers["Subject"] }, by: { $0 })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .prefix(5)
            if subjects.isEmpty { return "I couldn't find any subject line data in these emails." }
            var result = scopeLabel + "Here are the **most recurring subject lines** in your archive:\n\n"
            for (i, subject) in subjects.enumerated() {
                result += "\(i + 1). **\(subject.key)** — appeared \(subject.value) time\(subject.value == 1 ? "" : "s")\n"
            }
            result += "\nThese recurring subjects likely represent your most active conversations or ongoing threads."
            return result
        }

        if lower.contains("date") && (lower.contains("range") || lower.contains("when")) {
            let dates = scopedEmails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .long
                let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
                var result = scopeLabel + "Your email archive spans from **\(formatter.string(from: first))** to **\(formatter.string(from: last))**"
                if days > 0 {
                    result += " — that's about **\(days) days** (\(days / 30) months) of email history"
                }
                result += "."
                return result
            }
            return "I couldn't find any date information in these emails."
        }

        if lower.contains("reply") || lower.contains("statistic") {
            let sent = scopedEmails.filter { $0.messageType == "sent" }.count
            let received = scopedEmails.filter { $0.messageType == "received" }.count
            let ratio = received > 0 ? Double(sent) / Double(received) : 0
            var result = scopeLabel + "Here's a snapshot of your email activity:\n\n"
            result += "- **Sent**: \(sent) email\(sent == 1 ? "" : "s")\n"
            result += "- **Received**: \(received) email\(received == 1 ? "" : "s")\n"
            result += "- **Send/receive ratio**: \(String(format: "%.2f", ratio))\n\n"
            if ratio > 1.5 {
                result += "You're a prolific sender — you write significantly more emails than you receive."
            } else if ratio > 0.8 {
                result += "Your communication is fairly balanced between sending and receiving."
            } else if ratio > 0.3 {
                result += "You receive more emails than you send — you're more of a listener in your inbox."
            } else {
                result += "You're primarily on the receiving end, with most of your inbox being incoming messages."
            }
            return result
        }

        if lower.contains("attachment") {
            let total = scopedEmails.reduce(0) { $0 + $1.attachments.count }
            let withAttachments = scopedEmails.filter { !$0.attachments.isEmpty }.count
            let pctWithAtt = scopedEmails.count > 0 ? Int(Double(withAttachments) / Double(scopedEmails.count) * 100) : 0
            var result = scopeLabel + "Your archive contains **\(total) attachment\(total == 1 ? "" : "s")** spread across **\(withAttachments) email\(withAttachments == 1 ? "" : "s")** (\(pctWithAtt)% of your emails have attachments).\n\n"
            var typeCounts: [String: Int] = [:]
            for email in scopedEmails {
                for att in email.attachments {
                    let ext = (att.filename as NSString).pathExtension.lowercased()
                    typeCounts[ext.isEmpty ? "unknown" : ext, default: 0] += 1
                }
            }
            if !typeCounts.isEmpty {
                result += "**File types breakdown:**\n"
                for (ext, count) in typeCounts.sorted(by: { $0.value > $1.value }).prefix(8) {
                    let bar = String(repeating: "█", count: max(1, Int(Double(count) / Double(total) * 20)))
                    result += "- .**\(ext)**: \(count) \(bar)\n"
                }
            }
            return result
        }

        if lower.contains("phishing") || lower.contains("scam") || lower.contains("suspicious") || lower.contains("spam") || lower.contains("fraud") {
            let flags = EmailNLPEngine.detectPhishing(in: scopedEmails)
            if flags.isEmpty {
                return scopeLabel + "Good news — I scanned all **\(scopedEmails.count) emails** and didn't find any suspicious patterns. Your inbox looks clean."
            }
            let highRisk = flags.filter { $0.riskLevel == .high }
            let medRisk = flags.filter { $0.riskLevel == .medium }
            let lowRisk = flags.filter { $0.riskLevel == .low }
            var result = scopeLabel
            if highRisk.isEmpty {
                result += "I found **\(flags.count) email\(flags.count == 1 ? "" : "s")** with some suspicious characteristics, though none appear to be high-risk threats.\n\n"
            } else {
                result += "**Caution** — I found **\(highRisk.count) high-risk** email\(highRisk.count == 1 ? "" : "s") that show strong signs of phishing or scam activity"
                if medRisk.count + lowRisk.count > 0 { result += ", plus \(medRisk.count + lowRisk.count) with moderate or low concern" }
                result += ".\n\n"
            }
            for (i, flag) in flags.prefix(8).enumerated() {
                let from = flag.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? flag.email.headers["From"] ?? "?"
                let riskIcon = flag.riskLevel == .high ? "🔴" : flag.riskLevel == .medium ? "🟡" : "🟢"
                result += "\(i + 1). \(riskIcon) **\(flag.email.headers["Subject"] ?? "(No Subject)")**\n"
                result += "   From: **\(from)**\n"
                for reason in flag.reasons.prefix(3) { result += "   - \(reason)\n" }
                result += "\n"
            }
            if !highRisk.isEmpty {
                result += "**Recommendation:** Do not click links or download attachments from high-risk emails. If they claim to be from a known service, go directly to that service's website instead."
            }
            return result
        }

        if lower.contains("classify") || lower.contains("categorize") || lower.contains("category") || lower.contains("categories") || lower.contains("type of email") {
            let counts = EmailNLPEngine.classifyAll(scopedEmails)
            let sorted = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> (EmailNLPEngine.EmailCategory, Int)? in
                guard let count = counts[cat], count > 0 else { return nil }
                return (cat, count)
            }.sorted { $0.1 > $1.1 }
            if sorted.isEmpty { return scopeLabel + "I couldn't categorize these emails — there may not be enough content to classify." }
            let topCat = sorted[0]
            var result = scopeLabel + "Your inbox is primarily made up of **\(topCat.0.rawValue.lowercased())** emails (\(pct(topCat.1, scopedEmails.count))% of your archive). Here's the full breakdown:\n\n"
            for (cat, count) in sorted {
                let bar = String(repeating: "█", count: max(1, Int(Double(count) / Double(scopedEmails.count) * 20)))
                result += "- **\(cat.rawValue)**: \(count) (\(pct(count, scopedEmails.count))%) \(bar)\n"
            }
            result += "\nAsk about any category for more details, or try \"scan for phishing\" to check for suspicious emails."
            return result
        }

        if lower.contains("pii") || lower.contains("personal data") || lower.contains("gdpr") || lower.contains("compliance") || lower.contains("sensitive data") || lower.contains("privacy") {
            let summary = EmailNLPEngine.piiSummary(in: scopedEmails)
            if summary.isEmpty { return scopeLabel + "Good news — I scanned **\(scopedEmails.count) emails** and found **no personally identifiable information** (PII). Your archive appears clean from a data privacy standpoint." }
            let totalPII = summary.values.reduce(0, +)
            var result = scopeLabel + "I found **\(totalPII) instance\(totalPII == 1 ? "" : "s")** of potentially sensitive data across your emails:\n\n"
            for type in EmailNLPEngine.PIIType.allCases {
                let count = summary[type] ?? 0
                if count > 0 { result += "- **\(type.rawValue)**: \(count) instance\(count == 1 ? "" : "s")\n" }
            }
            result += "\n**Note:** If this archive may be subject to GDPR or other data protection regulations, consider redacting these items before sharing or exporting."
            return result
        }

        if lower.contains("priority") || lower.contains("important") || lower.contains("urgent") || lower.contains("missed") || lower.contains("action item") {
            let results = EmailNLPEngine.scoreAllPriorities(scopedEmails)
            let high = results.filter { $0.level == .high }
            let medium = results.filter { $0.level == .medium }
            let low = results.count - high.count - medium.count

            var result = scopeLabel
            if high.isEmpty && medium.isEmpty {
                result += "Everything looks manageable — I didn't find any high or medium priority emails that need your immediate attention.\n"
            } else if high.isEmpty {
                result += "No urgent items, but there are **\(medium.count) medium-priority** email\(medium.count == 1 ? "" : "s") worth reviewing.\n\n"
            } else {
                result += "You have **\(high.count) high-priority** email\(high.count == 1 ? "" : "s") that may need your attention"
                if medium.count > 0 { result += ", plus \(medium.count) at medium priority" }
                result += ".\n\n"
            }
            if !high.isEmpty {
                result += "**Needs attention:**\n\n"
                for (i, r) in high.prefix(5).enumerated() {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? r.email.headers["From"] ?? "?"
                    result += "\(i + 1). **\(r.email.headers["Subject"] ?? "(No Subject)")**\n"
                    result += "   From **\(from)** — \(r.reasons.joined(separator: ", "))\n\n"
                }
            }
            if !medium.isEmpty && high.count < 5 {
                result += "**Worth reviewing:**\n\n"
                for (i, r) in medium.prefix(3).enumerated() {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? r.email.headers["From"] ?? "?"
                    result += "\(i + 1). **\(r.email.headers["Subject"] ?? "(No Subject)")** from **\(from)**\n"
                    result += "   \(r.reasons.joined(separator: ", "))\n\n"
                }
            }
            if low > 0 { result += "The remaining \(low) email\(low == 1 ? "" : "s") are routine and low priority." }
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
            var result = scopeLabel + "Your email archive takes up **\(String(format: "%.1f", totalMB)) MB** across \(scopedEmails.count) emails. "
            let avgKB = scopedEmails.count > 0 ? Double(totalSize) / Double(scopedEmails.count) / 1024.0 : 0
            result += "That's an average of \(String(format: "%.0f", avgKB)) KB per email.\n\n"
            result += "**Biggest space consumers:**\n\n"
            for (i, entry) in topSenders.enumerated() {
                let name = entry.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? entry.key
                let mb = Double(entry.value.size) / (1024.0 * 1024.0)
                let pctOfTotal = totalSize > 0 ? Int(Double(entry.value.size) / Double(totalSize) * 100) : 0
                result += "\(i + 1). **\(name)** — \(String(format: "%.1f", mb)) MB (\(entry.value.count) emails, \(pctOfTotal)% of archive)\n"
            }
            if let topEntry = topSenders.first {
                let topName = topEntry.key.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? topEntry.key
                result += "\nIf you're looking to free up space, emails from **\(topName)** would be the best place to start."
            }
            return result
        }

        if lower.contains("contact profile") || lower.contains("who contacts") || lower.contains("relationship") || lower.contains("communication") {
            let insights = EmailNLPEngine.contactInsights(from: scopedEmails, limit: 8)
            if insights.isEmpty { return "I don't have enough contact data to build profiles. Try importing more emails." }
            var result = scopeLabel + "Here's a look at your **\(insights.count) most active contacts** and your communication patterns:\n\n"
            for (i, c) in insights.enumerated() {
                let addrPart = c.address.components(separatedBy: "<").last?.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) ?? c.address
                let name = c.address.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? c.address
                let contactEmails = scopedEmails.filter { ($0.headers["From"] ?? "").contains(addrPart) || ($0.headers["To"] ?? "").contains(addrPart) }
                let fromMe = contactEmails.filter { $0.messageType == "sent" }.count
                let toMe = contactEmails.filter { $0.messageType == "received" }.count
                let toneWord = c.avgSentiment > 0.1 ? "positive" : c.avgSentiment < -0.1 ? "critical" : "professional"
                let direction = fromMe > toMe * 2 ? "you write to them more" : toMe > fromMe * 2 ? "they write to you more" : "balanced two-way"
                result += "\(i + 1). **\(name)** — \(contactEmails.count) emails (\(direction)), tone is \(toneWord)\n"
            }
            result += "\nWant more detail? Ask \"tell me more about [name]\" for a full profile."
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

            var result = scopeLabel + "Here's a complete picture of your email archive:\n\n"

            // Volume & timeframe as a narrative
            result += "Your archive contains **\(scopedEmails.count) emails** — \(sent) sent and \(received) received — totaling \(String(format: "%.1f", sizeMB)) MB"
            if let first = dates.first, let last = dates.last {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                result += ", spanning from **\(formatter.string(from: first))** to **\(formatter.string(from: last))**"
            }
            result += "."
            if attachmentCount > 0 { result += " There are \(attachmentCount) attachments across these messages." }
            let primaryLang = languages.first?.language ?? "Unknown"
            if primaryLang != "Unknown" { result += " The primary language is \(primaryLang)." }
            result += "\n\n"

            // Tone summary
            let toneDesc: String
            if sentiment.average > 0.3 { toneDesc = "quite positive" }
            else if sentiment.average > 0.1 { toneDesc = "generally positive" }
            else if sentiment.average > -0.1 { toneDesc = "mostly neutral" }
            else if sentiment.average > -0.3 { toneDesc = "somewhat negative" }
            else { toneDesc = "noticeably negative" }
            result += "**Tone:** The overall sentiment is **\(toneDesc)** — \(pct(sentiment.positive, scopedEmails.count))% positive, \(pct(sentiment.neutral, scopedEmails.count))% neutral, and \(pct(sentiment.negative, scopedEmails.count))% negative.\n\n"

            // Categories as prose
            let catParts = EmailNLPEngine.EmailCategory.allCases.compactMap { cat -> String? in
                guard let count = classification[cat], count > 0 else { return nil }
                return "**\(cat.rawValue)** (\(pct(count, scopedEmails.count))%)"
            }
            if !catParts.isEmpty {
                result += "**Categories:** Your emails break down into \(catParts.joined(separator: ", ")).\n\n"
            }

            // Topics as prose
            if !topics.isEmpty {
                let topicWords = topics.prefix(5).map { "**\($0.word)**" }
                result += "**Key topics** include \(topicWords.joined(separator: ", "))"
                if topics.count > 5 { result += ", among others" }
                result += ".\n\n"
            }

            // People as prose
            if !entities.isEmpty {
                let entityNames = entities.prefix(5).map { "**\($0.name)**" }
                result += "**Key people and organizations** mentioned: \(entityNames.joined(separator: ", ")).\n\n"
            }

            if isScoped { result += "*This analysis covers \(scopedEmails.count) of \(emails.count) total emails in your archive.*\n\n" }
            result += "Ask me about any of these topics, people, or the sentiment for a deeper dive."
            return result
        }

        if lower.contains("thread") || lower.contains("conversation") {
            let threads = ThreadGrouper.group(scopedEmails)
            let multiMessage = threads.filter { $0.count > 1 }.sorted { $0.count > $1.count }
            if multiMessage.isEmpty { return scopeLabel + "I didn't find any conversation threads with back-and-forth replies. The emails may all be standalone messages." }
            var result = scopeLabel + "I found **\(multiMessage.count) active conversation\(multiMessage.count == 1 ? "" : "s")** (threads with replies) out of \(threads.count) total threads. Here are the most active:\n\n"
            for (i, thread) in multiMessage.prefix(8).enumerated() {
                let sentiment = EmailNLPEngine.averageSentiment(of: thread.allEmails)
                let trend = EmailNLPEngine.threadSentimentTrend(thread.allEmails)
                let participants = trend.participants.prefix(3).map { "**\($0)**" }.joined(separator: ", ")
                let toneWord = sentiment.average > 0.1 ? "positive" : sentiment.average < -0.1 ? "tense" : "neutral"
                result += "\(i + 1). **\(thread.subject)** — \(thread.count) messages, \(toneWord) tone (\(trend.overallTrend))\n"
                result += "   Between: \(participants)\n\n"
            }
            result += "Ask \"summarize thread\" for detailed summaries, or \"thread sentiment\" to see how the tone evolved in each conversation."
            return result
        }

        // MARK: - Greetings & Conversational
        let greetings = ["hello", "hi", "hey", "good morning", "good afternoon", "good evening", "howdy", "greetings", "yo", "sup", "what's up", "whats up"]
        if greetings.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + "!") || lower.hasPrefix($0 + ",") }) && lower.count < 30 {
            let sent = scopedEmails.filter { $0.messageType == "sent" }.count
            let received = scopedEmails.filter { $0.messageType == "received" }.count
            return "Hello! I'm your NLP email assistant. You have **\(scopedEmails.count) emails** loaded (\(sent) sent, \(received) received).\n\nI can help you with:\n- **Search**: \"Find emails about budget\" or \"emails from Sarah\"\n- **Analytics**: \"Who emails me most?\" or \"What topics come up?\"\n- **Sentiment**: \"What's the tone of my emails?\"\n- **Security**: \"Scan for phishing\" or \"Check for sensitive data\"\n- **Summary**: \"Give me a full overview\"\n\nWhat would you like to know?"
        }

        // MARK: - "When was the last email from X" / "latest email from X"
        let whenPatterns = ["when was the last", "when did .* last", "last email from", "latest email from", "most recent email from", "newest email from", "when did .* email", "last time .* emailed", "last time .* wrote"]
        let isWhenQuery = whenPatterns.contains { pattern in
            lower.range(of: pattern, options: .regularExpression) != nil
        }
        if isWhenQuery {
            let nameTerms = lower
                .replacingOccurrences(of: "when was the last email from", with: "")
                .replacingOccurrences(of: "when did", with: "")
                .replacingOccurrences(of: "last email", with: "")
                .replacingOccurrences(of: "latest email from", with: "")
                .replacingOccurrences(of: "most recent email from", with: "")
                .replacingOccurrences(of: "newest email from", with: "")
                .replacingOccurrences(of: "last time", with: "")
                .replacingOccurrences(of: "emailed", with: "")
                .replacingOccurrences(of: "wrote", with: "")
                .replacingOccurrences(of: "email me", with: "")
                .replacingOccurrences(of: "from", with: "")
                .replacingOccurrences(of: "?", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !nameTerms.isEmpty {
                let contactEmails = EmailNLPEngine.fuzzyMatchContacts(name: nameTerms, in: scopedEmails)
                if !contactEmails.isEmpty {
                    let sorted = contactEmails.sorted { a, b in
                        let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                        let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                        return da > db
                    }
                    let latest = sorted[0]
                    let formatter = DateFormatter()
                    formatter.dateStyle = .long
                    formatter.timeStyle = .short
                    let name = latest.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? nameTerms
                    let dateStr = latest.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? latest.headers["Date"] ?? "unknown date"
                    var result = "The most recent email from **\(name)** was on **\(dateStr)**.\n\n"
                    result += "**Subject:** \(latest.headers["Subject"] ?? "(No Subject)")\n"
                    let snippet = (latest.plainBody.isEmpty ? latest.htmlBody : latest.plainBody).prefix(200)
                    if !snippet.isEmpty { result += "**Preview:** \(snippet)...\n" }
                    result += "\nThey have **\(contactEmails.count) email\(contactEmails.count == 1 ? "" : "s")** total in your archive."
                    if sorted.count > 1 {
                        let secondDate = sorted[1].headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? "unknown"
                        result += " The one before that was on \(secondDate)."
                    }
                    return result
                }
                return "I couldn't find any emails from \"\(nameTerms)\" in your archive. Try checking the spelling or asking \"who emails me most?\" to see your contacts."
            }
        }

        // MARK: - Busiest day/time/hour analysis
        if lower.contains("busiest") || lower.contains("peak") || lower.contains("most active") || (lower.contains("when") && (lower.contains("most email") || lower.contains("most mail"))) {
            let calendar = Calendar.current
            var dayOfWeekCounts = [Int: Int]()
            var hourCounts = [Int: Int]()
            var monthCounts = [String: Int]()
            let monthFmt = DateFormatter()
            monthFmt.dateFormat = "MMMM yyyy"
            for email in scopedEmails {
                guard let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { continue }
                let weekday = calendar.component(.weekday, from: date)
                dayOfWeekCounts[weekday, default: 0] += 1
                let hour = calendar.component(.hour, from: date)
                hourCounts[hour, default: 0] += 1
                monthCounts[monthFmt.string(from: date), default: 0] += 1
            }
            let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let topDay = dayOfWeekCounts.max(by: { $0.value < $1.value })
            let topHour = hourCounts.max(by: { $0.value < $1.value })
            let topMonth = monthCounts.max(by: { $0.value < $1.value })

            var result = scopeLabel + "Here's when your inbox is most active:\n\n"
            if let day = topDay {
                result += "**Busiest day of the week:** \(dayNames[day.key]) (\(day.value) emails)\n"
                let quietDay = dayOfWeekCounts.min(by: { $0.value < $1.value })
                if let q = quietDay { result += "**Quietest day:** \(dayNames[q.key]) (\(q.value) emails)\n" }
            }
            if let hour = topHour {
                let hourStr = hour.key == 0 ? "12 AM" : hour.key < 12 ? "\(hour.key) AM" : hour.key == 12 ? "12 PM" : "\(hour.key - 12) PM"
                result += "**Peak hour:** \(hourStr) (\(hour.value) emails)\n"
            }
            if let month = topMonth {
                result += "**Busiest month:** \(month.key) (\(month.value) emails)\n"
            }
            result += "\n**Daily breakdown:**\n"
            for i in 1...7 {
                let count = dayOfWeekCounts[i] ?? 0
                let bar = String(repeating: "█", count: max(1, Int(Double(count) / Double(max(1, scopedEmails.count)) * 40)))
                result += "\(dayNames[i].padding(toLength: 10, withPad: " ", startingAt: 0)) \(bar) \(count)\n"
            }
            return result
        }

        // MARK: - Latest/newest/recent emails
        if (lower.contains("latest") || lower.contains("newest") || lower.contains("most recent") || lower.contains("recent email")) && !lower.contains("from") {
            let sorted = scopedEmails.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }
            let top = sorted.prefix(8)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            var result = scopeLabel + "Here are your **\(top.count) most recent emails**:\n\n"
            for (i, email) in top.enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? email.headers["From"] ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let hasAttach = email.attachments.isEmpty ? "" : " 📎"
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")**\(hasAttach)\n"
                result += "   From **\(from)** — \(dateStr)\n\n"
            }
            return result
        }

        // MARK: - Oldest/earliest emails
        if lower.contains("oldest") || lower.contains("earliest") || lower.contains("first email") {
            let sorted = scopedEmails.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantFuture
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantFuture
                return da < db
            }
            let top = sorted.prefix(8)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            var result = scopeLabel + "Here are the **\(top.count) oldest emails** in your archive:\n\n"
            for (i, email) in top.enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? email.headers["From"] ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")**\n"
                result += "   From **\(from)** — \(dateStr)\n\n"
            }
            return result
        }

        // MARK: - "Show me emails from [person]" or "emails from [person]"
        let fromPatterns = ["show me emails from", "show emails from", "emails from", "mail from", "messages from", "find emails from", "get emails from", "search emails from"]
        for pattern in fromPatterns {
            if lower.hasPrefix(pattern) {
                let nameStart = lower.replacingOccurrences(of: pattern, with: "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "?", with: "")
                if !nameStart.isEmpty {
                    let contactEmails = EmailNLPEngine.fuzzyMatchContacts(name: nameStart, in: scopedEmails)
                    if !contactEmails.isEmpty {
                        let sorted = contactEmails.sorted { a, b in
                            let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                            let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                            return da > db
                        }
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        let fromName = sorted.first?.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? nameStart
                        var result = "Found **\(contactEmails.count) email\(contactEmails.count == 1 ? "" : "s")** from **\(fromName)**:\n\n"
                        for (i, email) in sorted.prefix(10).enumerated() {
                            let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                            let hasAttach = email.attachments.isEmpty ? "" : " 📎"
                            result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")**\(hasAttach) — \(dateStr)\n"
                        }
                        if contactEmails.count > 10 { result += "\n...and \(contactEmails.count - 10) more." }
                        result += "\n\nAsk \"tell me more about \(nameStart)\" for a full contact profile."
                        return result
                    }
                    return "I couldn't find any emails from \"\(nameStart)\". Try \"who emails me most?\" to see your contacts."
                }
            }
        }

        // MARK: - "Thank you" / acknowledgements
        if lower.hasPrefix("thank") || lower == "thanks" || lower == "ok" || lower == "okay" || lower == "got it" || lower == "cool" || lower == "great" || lower == "nice" {
            return "You're welcome! Let me know if you'd like to explore anything else about your emails."
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
        if searchTerms.isEmpty, let range = dateRange {
            let results = EmailNLPEngine.searchWithDateFilter(terms: [], in: emails, dateRange: dateRange, limit: 15)
            if !results.isEmpty {
                return EmailNLPEngine.synthesizeAnswer(query: lower, terms: [], results: results, allEmails: emails, dateRange: dateRange)
            }
            return "I couldn't find any emails from \(range.label). You might want to check if your archive covers that time period, or try a broader date range."
        }

        if !searchTerms.isEmpty {
            var results = EmailNLPEngine.searchWithDateFilter(terms: searchTerms, in: emails, dateRange: dateRange, limit: 15)
            if !predictions.isEmpty {
                results = boostWithPredictions(results, predictions: predictions)
            }
            if !results.isEmpty {
                return EmailNLPEngine.synthesizeAnswer(query: lower, terms: searchTerms, results: results, allEmails: emails, dateRange: dateRange)
            }

            // Fallback: try carried names/topics if direct terms found nothing
            if !carriedNames.isEmpty && carriedNames != searchTerms {
                let fallbackTerms = searchTerms + carriedNames
                var fallbackResults = EmailNLPEngine.searchWithDateFilter(terms: fallbackTerms, in: emails, dateRange: dateRange, limit: 15)
                if !predictions.isEmpty {
                    fallbackResults = boostWithPredictions(fallbackResults, predictions: predictions)
                }
                if !fallbackResults.isEmpty {
                    return EmailNLPEngine.synthesizeAnswer(query: lower, terms: fallbackTerms, results: fallbackResults, allEmails: emails, dateRange: dateRange)
                }
            }
        }

        if EmailNLPEngine.isEmailRelated(lower, terms: searchTerms, emails: emails) {
            var suggestion = "I looked through all \(emails.count) emails in your archive but couldn't find anything matching that."
            if let range = dateRange {
                suggestion += " Nothing came up in \(range.label) either."
            }
            suggestion += "\n\nHere are some things you could try:\n"
            suggestion += "- Use a different spelling or a related keyword\n"
            suggestion += "- Ask about a specific person (e.g., \"emails from Sarah\")\n"
            suggestion += "- Try broader terms (e.g., \"meeting\" instead of \"standup\")\n"
            suggestion += "- Ask \"what topics are in my emails?\" to see what's there"
            return suggestion
        }

        // Smart fallback: guess what the user might want based on query words
        var suggestions: [String] = []
        if lower.contains("who") || lower.contains("person") || lower.contains("name") {
            suggestions.append("\"Who emails me most?\" — see your top contacts")
            suggestions.append("\"Tell me more about [name]\" — get a contact profile")
        }
        if lower.contains("when") || lower.contains("time") || lower.contains("day") || lower.contains("date") {
            suggestions.append("\"When is my inbox busiest?\" — see activity patterns")
            suggestions.append("\"Show me recent emails\" — see the latest messages")
        }
        if lower.contains("what") || lower.contains("about") {
            suggestions.append("\"What topics come up most?\" — discover key themes")
            suggestions.append("\"Give me a full summary\" — comprehensive overview")
        }
        if lower.contains("good") || lower.contains("bad") || lower.contains("feel") || lower.contains("happy") || lower.contains("angry") {
            suggestions.append("\"What's the sentiment?\" — analyze the tone of your emails")
        }
        if lower.contains("safe") || lower.contains("secure") || lower.contains("danger") || lower.contains("risk") || lower.contains("hack") {
            suggestions.append("\"Scan for phishing\" — check for suspicious emails")
            suggestions.append("\"Check for sensitive data\" — find PII in your archive")
        }
        if suggestions.isEmpty {
            suggestions = [
                "\"Give me a summary\" — full archive overview",
                "\"What topics come up?\" — discover themes",
                "\"Who emails me most?\" — see top contacts",
                "\"What's the sentiment?\" — tone analysis",
                "\"Find emails about [topic]\" — search your archive",
            ]
        }
        let suggestionList = suggestions.prefix(4).map { "- \($0)" }.joined(separator: "\n")
        return "I'm not sure I understood that, but I can analyze your \(emails.count) emails in many ways. Try one of these:\n\n\(suggestionList)\n\nOr type **help** to see everything I can do!"
    }

    // MARK: - Hybrid NLP + Apple AI

    nonisolated private static func isOpenEndedQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        // Structured handlers that NLP handles better than LLM (deterministic, exact)
        let structuredKeywords: [String] = [
            "phishing", "scam", "suspicious", "spam", "fraud",
            "pii", "gdpr", "compliance", "sensitive data", "privacy",
            "classify", "categorize", "category", "categories",
            "how many", "how much", "count", "total number",
            "date range", "attachment",
            "cleanup", "storage", "disk", "space",
            "statistic", "reply ratio",
            "language", "translate",
        ]
        if structuredKeywords.contains(where: { lower.contains($0) }) {
            return false
        }
        return true
    }

    nonisolated private static func retrieveRelevantEmails(query: String, emails: [MBOXParser.RawEmail], priorContext: String, predictions: [UUID: Double]) -> [MBOXParser.RawEmail] {
        let resolved = resolveConversationContext(query: query.lowercased(), priorContext: priorContext)
        let lower = resolved.query
        var searchTerms = EmailNLPEngine.extractSearchTerms(from: lower)
        let dateRange = EmailNLPEngine.parseDateRange(from: lower)

        if searchTerms.isEmpty && !resolved.names.isEmpty {
            searchTerms = resolved.names
        }

        // Person query
        if let name = resolved.names.first, !name.isEmpty {
            let contacts = EmailNLPEngine.fuzzyMatchContacts(name: name, in: emails)
            if contacts.count >= 2 { return Array(contacts.prefix(20)) }
        }

        // Search with BM25 + semantic
        if !searchTerms.isEmpty {
            let indexResults = EmailSearchIndex.shared.hybridSearch(query: lower, terms: searchTerms, limit: 20)
            if indexResults.count >= 3 {
                var results = indexResults
                if !predictions.isEmpty {
                    results = boostWithPredictions(results, predictions: predictions).map { $0 }
                }
                return results.map(\.email)
            }
            let fallback = EmailNLPEngine.searchWithDateFilter(terms: searchTerms, in: emails, dateRange: dateRange, limit: 20)
            if !fallback.isEmpty { return fallback.map(\.email) }
        }

        // Date-only queries
        if let range = dateRange {
            return emails.filter { email in
                guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                return d >= range.start && d <= range.end
            }.prefix(20).map { $0 }
        }

        return Array(emails.prefix(30))
    }

    private func hybridAppleAISynthesis(query: String, retrievedEmails: [MBOXParser.RawEmail], nlpAnalysis: String, allEmailCount: Int) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await FoundationModelEngine.synthesizeFromNLPResults(
                            query: query,
                            retrievedEmails: retrievedEmails,
                            nlpAnalysis: nlpAnalysis,
                            allEmailCount: allEmailCount
                        ) { partial in
                            self.streamingAnswer = partial
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(45))
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        return nlpAnalysis
                    }
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                return streamingAnswer.isEmpty ? nlpAnalysis : streamingAnswer
            } catch is TimeoutError {
                return streamingAnswer.isEmpty ? nlpAnalysis : streamingAnswer + "\n\n(Apple AI timed out — showing partial result)"
            } catch {
                return nlpAnalysis
            }
        }
        #endif
        return nlpAnalysis
    }

    // MARK: - Agentic RAG

    private struct AgenticRAGResult {
        let retrievedEmails: [MBOXParser.RawEmail]
        let keyChunks: [(subject: String, from: String, chunk: String)]
        let threadTimeline: String
        let enrichedAnalysis: String
        let steps: [String]
    }

    nonisolated private static func agenticRetrieve(
        query: String,
        emails: [MBOXParser.RawEmail],
        priorContext: String,
        predictions: [UUID: Double],
        priorRetrievedIDs: Set<UUID> = []
    ) -> AgenticRAGResult {
        var steps: [String] = []
        let resolved = resolveConversationContext(query: query.lowercased(), priorContext: priorContext)
        let lower = resolved.query
        var searchTerms = EmailNLPEngine.extractSearchTerms(from: lower)
        let dateRange = EmailNLPEngine.parseDateRange(from: lower)

        if searchTerms.isEmpty && !resolved.names.isEmpty {
            searchTerms = resolved.names
        }

        // === Step 1: Initial broad retrieval ===
        var initialEmails: [MBOXParser.RawEmail] = []

        if let name = resolved.names.first, !name.isEmpty {
            let contacts = EmailNLPEngine.fuzzyMatchContacts(name: name, in: emails)
            if contacts.count >= 2 {
                initialEmails = Array(contacts.prefix(25))
                steps.append("Found \(contacts.count) emails involving \(name)")
            }
        }

        if initialEmails.isEmpty && !searchTerms.isEmpty {
            let indexResults = EmailSearchIndex.shared.hybridSearch(query: lower, terms: searchTerms, limit: 25)
            if indexResults.count >= 3 {
                var results = indexResults
                if !predictions.isEmpty {
                    results = boostWithPredictions(results, predictions: predictions)
                }
                initialEmails = results.map(\.email)
                steps.append("BM25+semantic search: \(initialEmails.count) emails for [\(searchTerms.joined(separator: ", "))]")
            } else {
                let fallback = EmailNLPEngine.searchWithDateFilter(terms: searchTerms, in: emails, dateRange: dateRange, limit: 25)
                initialEmails = fallback.map(\.email)
                if !initialEmails.isEmpty {
                    steps.append("Linear search fallback: \(initialEmails.count) emails")
                }
            }
        }

        if initialEmails.isEmpty, let range = dateRange {
            initialEmails = emails.filter { email in
                guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                return d >= range.start && d <= range.end
            }.prefix(25).map { $0 }
            steps.append("Date filter: \(initialEmails.count) emails in \(range.label)")
        }

        if initialEmails.isEmpty {
            initialEmails = Array(emails.prefix(30))
            steps.append("Using top 30 emails by position")
        }

        // === Step 2: Thread expansion ===
        let beforeExpansion = initialEmails.count
        let expanded = EmailSearchIndex.shared.expandByThread(initialEmails, allEmails: emails)
        if expanded.count > beforeExpansion {
            steps.append("Thread expansion: \(beforeExpansion) → \(expanded.count) emails (+\(expanded.count - beforeExpansion) from same threads)")
        }

        var finalEmails = expanded
        if let range = dateRange {
            finalEmails = expanded.filter { email in
                guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return true }
                return d >= range.start && d <= range.end
            }
        }
        if !priorRetrievedIDs.isEmpty {
            let novel = finalEmails.filter { !priorRetrievedIDs.contains($0.id) }
            let seen = finalEmails.filter { priorRetrievedIDs.contains($0.id) }
            finalEmails = Array((novel + seen).prefix(30))
            if !novel.isEmpty && !seen.isEmpty {
                steps.append("Follow-up dedup: \(novel.count) new + \(seen.count) prior emails")
            }
        } else {
            finalEmails = Array(finalEmails.prefix(30))
        }

        // === Step 3: Chunk-level extraction ===
        let chunkResults = EmailSearchIndex.shared.chunkSearch(terms: searchTerms, in: finalEmails, maxChunksPerEmail: 2, limit: 10)
        let keyChunks: [(subject: String, from: String, chunk: String)] = chunkResults.map { result in
            let from = result.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            return (
                subject: result.email.headers["Subject"] ?? "(No Subject)",
                from: from,
                chunk: String(result.chunk.prefix(400))
            )
        }
        if !keyChunks.isEmpty {
            steps.append("Chunk extraction: \(keyChunks.count) key passages")
        }

        // === Step 4: Thread timeline ===
        let threads = ThreadGrouper.group(finalEmails)
        let multiMessage = threads.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        var timeline = ""
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short

        if !multiMessage.isEmpty {
            timeline += "CONVERSATION THREADS:\n"
            for thread in multiMessage.prefix(5) {
                timeline += "\n\"\(thread.subject)\" (\(thread.count) emails):\n"
                let sorted = thread.allEmails.sorted {
                    (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) <
                    (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
                }
                for email in sorted {
                    let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
                    let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }).map { dateFmt.string(from: $0) } ?? "?"
                    let sentimentResults = EmailNLPEngine.analyzeSentiment(of: [email])
                    let tone = sentimentResults.first?.label ?? "Neutral"
                    timeline += "  → \(date) | \(from) | \(tone)\n"
                }
                let trend = EmailNLPEngine.threadSentimentTrend(thread.allEmails)
                timeline += "  Trend: \(trend.overallTrend)\n"
            }
            steps.append("Thread timeline: \(multiMessage.count) conversation\(multiMessage.count == 1 ? "" : "s")")
        }

        // === Step 5: Enriched NLP analysis ===
        var analysis = ""
        let sentiment = EmailNLPEngine.averageSentiment(of: finalEmails)
        analysis += "Sentiment: \(sentiment.label) (avg \(String(format: "%.2f", sentiment.average))). "
        analysis += "Positive: \(sentiment.positive), Neutral: \(sentiment.neutral), Negative: \(sentiment.negative)\n"

        let entities = EmailNLPEngine.extractEntities(from: finalEmails, limit: 5)
        if !entities.isEmpty {
            analysis += "Entities: \(entities.map { "\($0.name) (\($0.type), \($0.count)x)" }.joined(separator: ", "))\n"
        }

        let topics = EmailNLPEngine.extractTopics(from: finalEmails, limit: 5)
        if !topics.isEmpty {
            analysis += "Topics: \(topics.map { "\($0.word) (\($0.count)x)" }.joined(separator: ", "))\n"
        }

        let sent = finalEmails.filter { $0.messageType == "sent" }.count
        let recv = finalEmails.filter { $0.messageType == "received" }.count
        analysis += "Direction: \(sent) sent, \(recv) received\n"

        return AgenticRAGResult(
            retrievedEmails: finalEmails,
            keyChunks: keyChunks,
            threadTimeline: timeline,
            enrichedAnalysis: analysis,
            steps: steps
        )
    }

    private func hybridAgenticSynthesis(query: String, ragResult: AgenticRAGResult, nlpFallback: String, allEmailCount: Int) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await FoundationModelEngine.synthesizeFromAgenticRAG(
                            query: query,
                            retrievedEmails: ragResult.retrievedEmails,
                            keyChunks: ragResult.keyChunks,
                            threadTimeline: ragResult.threadTimeline,
                            nlpAnalysis: ragResult.enrichedAnalysis,
                            retrievalSteps: ragResult.steps,
                            allEmailCount: allEmailCount
                        ) { partial in
                            self.streamingAnswer = partial
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(45))
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        return nlpFallback
                    }
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                return streamingAnswer.isEmpty ? nlpFallback : streamingAnswer
            } catch is TimeoutError {
                return streamingAnswer.isEmpty ? nlpFallback : streamingAnswer + "\n\n(Apple AI timed out — showing partial result)"
            } catch {
                return nlpFallback
            }
        }
        #endif
        return nlpFallback
    }

    // MARK: - Query Decomposition

    private struct DecomposedQuery {
        let contentTerms: [String]
        let personTerms: [String]
        let sentimentFilter: String
        let hasPriorityFilter: Bool
        let dateRange: EmailNLPEngine.DateRange?
    }

    nonisolated private static func decomposeQuery(_ query: String) -> DecomposedQuery {
        let lower = query.lowercased()
        let dateRange = EmailNLPEngine.parseDateRange(from: lower)

        // Detect sentiment/priority qualifiers
        let sentimentFilter: String
        let positiveWords = ["positive", "happy", "warm", "friendly", "upbeat"]
        let negativeWords = ["angry", "upset", "frustrated", "heated", "critical", "negative", "tense", "concerned"]
        if positiveWords.contains(where: { lower.contains($0) }) { sentimentFilter = "positive" }
        else if negativeWords.contains(where: { lower.contains($0) }) { sentimentFilter = "negative" }
        else { sentimentFilter = "" }

        let priorityWords = ["urgent", "important", "critical", "high priority", "action required"]
        let hasPriority = priorityWords.contains(where: { lower.contains($0) })

        // Extract person names
        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = query
        var personTerms: [String] = []
        nameTagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, range in
            if tag == .personalName || tag == .organizationName {
                personTerms.append(String(query[range]))
            }
            return true
        }

        var contentTerms = EmailNLPEngine.extractSearchTerms(from: lower)
        let filterWords: Set<String> = Set(positiveWords + negativeWords + priorityWords + ["urgent", "important"])
        contentTerms = contentTerms.filter { !filterWords.contains($0.lowercased()) }

        return DecomposedQuery(
            contentTerms: contentTerms,
            personTerms: personTerms,
            sentimentFilter: sentimentFilter,
            hasPriorityFilter: hasPriority,
            dateRange: dateRange
        )
    }

    nonisolated private static func executeDecomposedQuery(_ parts: DecomposedQuery, emails: [MBOXParser.RawEmail]) -> [EmailNLPEngine.SearchResult] {
        var candidates = emails

        // Filter by person
        if let person = parts.personTerms.first {
            candidates = EmailNLPEngine.fuzzyMatchContacts(name: person, in: candidates)
        }

        // Filter by date
        if let range = parts.dateRange {
            candidates = candidates.filter { email in
                guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                return d >= range.start && d <= range.end
            }
        }

        // Search by content terms
        var results: [EmailNLPEngine.SearchResult]
        if !parts.contentTerms.isEmpty {
            results = EmailNLPEngine.searchEmails(terms: parts.contentTerms, in: candidates, limit: 30)
        } else {
            results = candidates.prefix(30).map {
                EmailNLPEngine.SearchResult(email: $0, score: 1.0, matchContext: "")
            }
        }

        // Apply sentiment filter
        if !parts.sentimentFilter.isEmpty {
            let sentiments = EmailNLPEngine.analyzeSentiment(of: results.map(\.email))
            let sentimentMap = Dictionary(uniqueKeysWithValues: sentiments.map { ($0.email.id, $0.score) })
            results = results.filter { r in
                let score = sentimentMap[r.email.id] ?? 0
                if parts.sentimentFilter == "positive" { return score > 0.1 }
                if parts.sentimentFilter == "negative" { return score < -0.1 }
                return true
            }
            // Re-score by sentiment extremity
            results.sort { a, b in
                let sA = sentimentMap[a.email.id] ?? 0
                let sB = sentimentMap[b.email.id] ?? 0
                if parts.sentimentFilter == "negative" { return sA < sB }
                return sA > sB
            }
        }

        // Apply priority filter
        if parts.hasPriorityFilter {
            let priorities = results.map { EmailNLPEngine.scorePriority($0.email) }
            let highPriority = zip(results, priorities).filter { $0.1.level == .high || $0.1.level == .medium }
            if !highPriority.isEmpty {
                results = highPriority.sorted { $0.1.score > $1.1.score }.map { $0.0 }
            }
        }

        return Array(results.prefix(15))
    }

    // MARK: - PredictiveCoding Relevance Boost

    nonisolated private static func boostWithPredictions(_ results: [EmailNLPEngine.SearchResult], predictions: [UUID: Double]) -> [EmailNLPEngine.SearchResult] {
        guard !predictions.isEmpty else { return results }
        return results.map { result in
            let prediction = predictions[result.email.id] ?? 0.5
            let boost = 1.0 + (prediction - 0.5) * 0.6
            return EmailNLPEngine.SearchResult(
                email: result.email,
                score: result.score * boost,
                matchContext: result.matchContext
            )
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Conversation Context Resolution

    private struct ResolvedContext {
        let query: String
        let names: [String]
        let topics: [String]
    }

    nonisolated private static func resolveConversationContext(query: String, priorContext: String) -> ResolvedContext {
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

    nonisolated private static func buildContactProfile(name: String, emails: [MBOXParser.RawEmail], allEmails: [MBOXParser.RawEmail]) -> String {
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

        let toneDesc: String
        if sentiment.average > 0.3 { toneDesc = "very positive" }
        else if sentiment.average > 0.1 { toneDesc = "friendly and positive" }
        else if sentiment.average > -0.1 { toneDesc = "professional and neutral" }
        else if sentiment.average > -0.3 { toneDesc = "somewhat formal or critical" }
        else { toneDesc = "notably direct or negative" }

        var result = "Here's what I know about **\(displayName)**:\n\n"

        // Overview narrative
        result += "You have **\(emails.count) emails** with \(displayName)"
        if fromMe.count > 0 && toMe.count > 0 {
            result += " — you've sent them \(fromMe.count) and received \(toMe.count)"
        } else if toMe.count > 0 {
            result += " — all \(toMe.count) received from them"
        } else if fromMe.count > 0 {
            result += " — all \(fromMe.count) sent by you"
        }
        result += ". "
        if !threads.isEmpty { result += "There are \(threads.count) threaded conversations between you. " }
        result += "The overall tone of your exchanges is **\(toneDesc)**.\n\n"

        // Time range
        if let first = dates.first, let last = dates.last {
            if first == last {
                result += "Your correspondence was on **\(dateFmt.string(from: first))**.\n\n"
            } else {
                result += "Your correspondence spans from **\(dateFmt.string(from: first))** to **\(dateFmt.string(from: last))**.\n\n"
            }
        }

        // Topics as narrative
        if !subjects.isEmpty {
            let cleaned = subjects.map { $0.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") }
            let unique = Array(Set(cleaned))
            if unique.count == 1 {
                result += "**Topic discussed:** \(unique[0])\n\n"
            } else {
                result += "**Topics discussed** (\(unique.count)):\n"
                for subj in unique.prefix(8) {
                    result += "- \(subj)\n"
                }
                if unique.count > 8 { result += "- ...and \(unique.count - 8) more\n" }
                result += "\n"
            }
        }

        // Recent emails with narrative framing
        result += "**Recent activity:**\n\n"
        let sortedByDate = emails.sorted {
            (MBOXParser.parseDate($0.headers["Date"]) ?? .distantPast) >
            (MBOXParser.parseDate($1.headers["Date"]) ?? .distantPast)
        }
        for (i, email) in sortedByDate.prefix(6).enumerated() {
            let date = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }
            let dateStr = date.map { dateFmt.string(from: $0) } ?? ""
            let direction = email.messageType == "sent" ? "You wrote" : "\(displayName) wrote"
            result += "\(i + 1). \(direction) on \(dateStr): \"\(email.headers["Subject"] ?? "(No Subject)")\"\n"
        }
        if emails.count > 6 { result += "   ...plus \(emails.count - 6) earlier emails\n" }

        let otherContacts = Set(emails.compactMap { $0.headers["To"] }).union(Set(emails.compactMap { $0.headers["Cc"] }))
        let filteredContacts = otherContacts.filter { !$0.lowercased().contains(name.lowercased()) }
        if !filteredContacts.isEmpty {
            let contactNames = filteredContacts.prefix(5).map {
                $0.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? $0
            }
            result += "\n\(displayName) also appears in conversations with \(contactNames.joined(separator: ", ")).\n"
        }

        return result
    }

    nonisolated private static func pct(_ count: Int, _ total: Int) -> String {
        String(format: "%.0f", Double(count) / Double(max(total, 1)) * 100)
    }

    // MARK: - Conversation Persistence

    private struct SavedTurn: Codable {
        let query: String
        let answer: String
        var timestamp: Date?
    }

    nonisolated private static var conversationURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai_conversation.json")
    }

    private func saveConversation() {
        guard !conversationHistory.isEmpty else { return }
        let turns = conversationHistory.suffix(20).map { SavedTurn(query: $0.query, answer: $0.answer, timestamp: $0.timestamp) }
        if let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: Self.conversationURL, options: .atomic)
        }
    }

    private func loadConversation() {
        guard conversationHistory.isEmpty,
              let data = try? Data(contentsOf: Self.conversationURL),
              let turns = try? JSONDecoder().decode([SavedTurn].self, from: data) else { return }
        conversationHistory = turns.map { (query: $0.query, answer: $0.answer, timestamp: $0.timestamp ?? Date()) }
    }

    nonisolated static func clearSavedConversation() {
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

        let timeFmt = DateFormatter()
        timeFmt.timeStyle = .short
        for (i, turn) in conversationHistory.enumerated() {
            let timeStr = timeFmt.string(from: turn.timestamp)
            markdown += "### Q\(i + 1) [\(timeStr)]: \(turn.query)\n\n"
            markdown += "\(turn.answer)\n\n---\n\n"
        }

        markdown += "*Report generated by mailin — privacy-first email archive analyzer*\n"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export AI Report"
        panel.nameFieldStringValue = "mailin-report-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-report.md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        shareItems = [url]
        showShareSheet = true
        #endif
    }
}

#Preview {
    AIAssistantView(allEmails: [], filteredEmails: [], selectedEmails: [])
}
