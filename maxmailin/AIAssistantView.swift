import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import NaturalLanguage
import UniformTypeIdentifiers

/// Scope semantics for the AI assistant — replaces the legacy corpus arrays
/// (whole-corpus or filtered-list arrays). Callers pass the CURRENT
/// archive filter as an `EmailQuery` plus the explicitly selected ids; the
/// view resolves them against the bounded store (counts via the repository,
/// analysis over a capped hydrated working set, search via FTS5) — never a
/// whole-archive array.
struct AIAssistantScope {
    /// The caller's current filter state mapped to an archive query
    /// (`.all` when nothing is filtered).
    var filteredQuery: EmailQuery = .all
    /// Explicit user selection (bounded by what a human can select by hand).
    var selectedIDs: [EmailID] = []

    static let all = AIAssistantScope()
}

/// Kept out of AIAssistantView's body chain — that expression is at the
/// type-checker's complexity limit; a modifier adds one cheap call.
private struct ReportExportErrorAlert: ViewModifier {
    @Binding var error: String?
    func body(content: Content) -> some View {
        content.alert("Report export failed", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

struct AIAssistantView: View {
    let archiveScope: AIAssistantScope
    var searchContext: String = ""
    var onSelectEmail: ((UUID) -> Void)?
    var onFilterByIDs: (([UUID]) -> Void)?

    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    @State private var prompt = ""
    @State private var isProcessing = false
    @State private var conversationHistory: [(query: String, answer: String, timestamp: Date, relatedEmailIDs: [UUID])] = []
    @State private var selectedEngine: AIEngine = .auto
    @State private var emailScope: EmailScope = .filtered
    @State private var currentTask: Task<Void, Never>?
    @State private var streamingQuery = ""
    @State private var streamingAnswer = ""
    @AppStorage("freeAIQueryCount") private var freeQueryCount: Int = 0
    @State private var showUpgradePaywall = false
    @State private var showActionConfirmation = false
    @State private var pendingActionDescription = ""
    @State private var actionConfirmationContinuation: CheckedContinuation<Bool, Never>?
    @State private var priorRetrievedEmailIDs: Set<UUID> = []
    @State private var lastRetrievedEmailIDs: [UUID] = []
    @State private var showTutorial = false
    @EnvironmentObject private var storeManager: StoreManager

    static let freeQueryLimit = 5

    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif
    @State private var reportExportError: String?

    @Environment(\.dismiss) private var dismiss

    private enum AIEngine: String, CaseIterable {
        case auto = "Auto"
        case appleAIMoE = "Apple AI MoE"
        case appleAI = "Apple AI"
        case hybrid = "Hybrid"
        #if !OFFLINE_MODE
        case cloudAI = "Cloud AI"
        #endif
        case nlp = "NLP"
    }

    enum EmailScope: String, CaseIterable {
        case all = "All Emails"
        case filtered = "Filtered"
        case selected = "Selected"
    }

    // MARK: - Bounded working set (Part D)
    //
    // The view NEVER receives or holds the archive. `workingSet` is a capped
    // hydration of the active scope streamed from the bounded store (the same
    // precedent GeneralAnalysisView/ForensicReviewView use); true scope-wide
    // counts come from the repository; per-id lookups hydrate on demand.

    static let workingSetCap = 2_000

    @State private var workingSet: [MBOXParser.RawEmail] = []
    @State private var hydratedScope: EmailScope?
    @State private var scopeCounts: [EmailScope: Int] = [:]
    @State private var hydratedByID: [UUID: MBOXParser.RawEmail] = [:]

    /// Bounded working set for the active scope (may still be hydrating).
    private var emails: [MBOXParser.RawEmail] { workingSet }

    private func resolvedSelection(for scope: EmailScope) -> ArchiveSelectionScope {
        switch scope {
        case .all:
            return .query(.all, exclusions: [])
        case .filtered:
            return .query(archiveScope.filteredQuery, exclusions: [])
        case .selected:
            if archiveScope.selectedIDs.isEmpty {
                return .query(archiveScope.filteredQuery, exclusions: [])
            }
            return .explicit(Set(archiveScope.selectedIDs))
        }
    }

    private func hydrateWorkingSet(for scope: EmailScope) async {
        let selection = resolvedSelection(for: scope)
        var acc: [MBOXParser.RawEmail] = []
        let stream = ArchiveDataService.shared.streamSelected(scope: selection, batchSize: 200)
        do {
            for try await batch in stream {
                acc.append(contentsOf: batch)
                if acc.count >= Self.workingSetCap { break }
            }
        } catch { }
        workingSet = Array(acc.prefix(Self.workingSetCap))
        hydratedScope = scope
    }

    /// The bounded working set for the CURRENT scope, hydrating first if needed.
    private func currentWorkingSet() async -> [MBOXParser.RawEmail] {
        if hydratedScope != emailScope || (workingSet.isEmpty && emailCount(for: emailScope) > 0) {
            await hydrateWorkingSet(for: emailScope)
        }
        return workingSet
    }

    /// True scope-wide counts from the repository (O(1) memory) — the picker
    /// shows real archive numbers even though analysis is capped.
    private func refreshScopeCounts() async {
        scopeCounts[.all] = (try? await ArchiveDataService.shared.count(query: .all)) ?? 0
        scopeCounts[.filtered] = (try? await ArchiveDataService.shared.count(query: archiveScope.filteredQuery)) ?? scopeCounts[.all] ?? 0
        scopeCounts[.selected] = archiveScope.selectedIDs.count
    }

    /// Per-id lookup against the bounded caches (related-email cards).
    private func cachedEmail(id: UUID) -> MBOXParser.RawEmail? {
        hydratedByID[id] ?? workingSet.first { $0.id == id }
    }

    /// Hydrate a bounded batch of related-email ids for card rendering.
    private func hydrateRelated(ids: [UUID]) async {
        let missing = ids.filter { cachedEmail(id: $0) == nil }
        guard !missing.isEmpty else { return }
        let fetched = (try? await ArchiveDataService.shared.fullEmails(ids: Array(missing.prefix(60)))) ?? []
        for email in fetched { hydratedByID[email.id] = email }
        // Keep the cache bounded.
        if hydratedByID.count > 300 {
            let overflow = hydratedByID.count - 300
            for key in hydratedByID.keys.prefix(overflow) { hydratedByID.removeValue(forKey: key) }
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

    private var cloudAIAvailable: Bool {
        #if !OFFLINE_MODE
        CloudAIManager.shared.isReady && !forensicManager.isEnabled
        #else
        false
        #endif
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
        .frame(minWidth: 460, idealWidth: 700, minHeight: 380, idealHeight: 650)
        #endif
        .background(AppColors.backgroundTertiary)
        .onAppear {
            selectedEngine = .auto
            if !archiveScope.selectedIDs.isEmpty {
                emailScope = .selected
            }
            loadConversation()
        }
        .task {
            await refreshScopeCounts()
            await hydrateWorkingSet(for: emailScope)
            let savedIDs = conversationHistory.flatMap(\.relatedEmailIDs)
            if !savedIDs.isEmpty { await hydrateRelated(ids: Array(savedIDs.suffix(60))) }
        }
        .onChange(of: emailScope) { _, newScope in
            Task { await hydrateWorkingSet(for: newScope) }
        }
        .onChange(of: conversationHistory.count) { _, _ in
            guard let last = conversationHistory.last, !last.relatedEmailIDs.isEmpty else { return }
            Task { await hydrateRelated(ids: last.relatedEmailIDs) }
        }
        .onDisappear {
            currentTask?.cancel()
            currentTask = nil
            saveConversation()
        }
        #if !DEBUG
        .sheet(isPresented: $showUpgradePaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        #endif
        .alert("Confirm Action", isPresented: $showActionConfirmation) {
            Button("Execute", role: .destructive) {
                actionConfirmationContinuation?.resume(returning: true)
                actionConfirmationContinuation = nil
            }
            Button("Skip", role: .cancel) {
                actionConfirmationContinuation?.resume(returning: false)
                actionConfirmationContinuation = nil
            }
        } message: {
            Text("The AI wants to: \(pendingActionDescription)\n\nThis action will modify your data. Proceed?")
        }
        .modifier(ReportExportErrorAlert(error: $reportExportError))
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
        .featureTutorial(.aiAssistant, key: "ai_assistant_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showProvenanceSheet) {
            NavigationStack {
                if let latest = provenanceStore.recent.first {
                    AIProvenanceView(provenance: latest)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showProvenanceSheet = false }
                            }
                        }
                } else {
                    VStack(spacing: Spacing.medium) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Provenance will appear after your first AI answer.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showProvenanceSheet = false }
                        }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
            #endif
        }
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
            #if os(iOS)
            VStack(spacing: 8) {
                HStack {
                    aiHeaderIcon
                    Text("AI Assistant")
                        .font(.headline)
                    Spacer()
                    if isProcessing {
                        Button {
                            currentTask?.cancel()
                            currentTask = nil
                            isProcessing = false
                            streamingQuery = ""
                            streamingAnswer = ""
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(AppColors.error)
                        }
                        .buttonStyle(.borderless)
                    }
                    Button(action: exportConversation) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(conversationHistory.isEmpty)
                    Button {
                        conversationHistory.removeAll()
                        Self.clearSavedConversation()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(conversationHistory.isEmpty)
                    TutorialHelpButton(showTutorial: $showTutorial)
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }

                HStack(spacing: 8) {
                    Menu {
                        Button { selectedEngine = .auto } label: {
                            Label("Auto", systemImage: selectedEngine == .auto ? "checkmark" : "wand.and.stars")
                        }
                        if foundationModelAvailable {
                            Button { selectedEngine = .appleAIMoE } label: {
                                Label("Apple AI MoE", systemImage: selectedEngine == .appleAIMoE ? "checkmark" : "brain")
                            }
                            Button { selectedEngine = .appleAI } label: {
                                Label("Apple AI", systemImage: selectedEngine == .appleAI ? "checkmark" : "cpu")
                            }
                            Button { selectedEngine = .hybrid } label: {
                                Label("Hybrid", systemImage: selectedEngine == .hybrid ? "checkmark" : "sparkles")
                            }
                        }
                        #if !OFFLINE_MODE
                        if cloudAIAvailable {
                            Button { selectedEngine = .cloudAI } label: {
                                Label("Cloud AI", systemImage: selectedEngine == .cloudAI ? "checkmark" : "cloud")
                            }
                        }
                        #endif
                        Button { selectedEngine = .nlp } label: {
                            Label("NLP", systemImage: selectedEngine == .nlp ? "checkmark" : "text.magnifyingglass")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.caption)
                            Text(selectedEngine.rawValue)
                                .font(.subheadline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(8)
                    }

                    Menu {
                        Button { emailScope = .all } label: {
                            Label("All (\(emailCount(for: .all)))", systemImage: emailScope == .all ? "checkmark" : "tray.full")
                        }
                        Button { emailScope = .filtered } label: {
                            Label("Filtered (\(emailCount(for: .filtered)))", systemImage: emailScope == .filtered ? "checkmark" : "line.3.horizontal.decrease")
                        }
                        Button { emailScope = .selected } label: {
                            Label("Selected (\(emailCount(for: .selected)))", systemImage: emailScope == .selected ? "checkmark" : "checkmark.circle")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope")
                                .font(.caption)
                            Text("\(emailCount(for: emailScope)) emails")
                                .font(.subheadline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(8)
                    }

                    Spacer()

                    if !storeManager.isPremium {
                        let remaining = max(0, Self.freeQueryLimit - freeQueryCount)
                        Text(remaining > 0 ? "\(remaining) free" : "Limit")
                            .font(.system(.caption2, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundColor(remaining > 0 ? AppColors.secondary : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(remaining > 0 ? AppColors.backgroundSecondary : Color.orange.opacity(0.12))
                            .cornerRadius(CornerRadius.round)
                    }
                }

                Text(engineDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppColors.backgroundPrimary)
            #else
            HStack(spacing: Spacing.small) {
                aiHeaderIcon

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Spacing.xxSmall) {
                        Text("AI Email Assistant")
                            .font(Typography.headline)
                        if foundationModelAvailable {
                            Text("Apple Intelligence")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .leading, endPoint: .trailing)
                                )
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        LinearGradient(colors: [.purple.opacity(0.1), .blue.opacity(0.08), .cyan.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                                    )
                                )
                        }
                    }
                    Text(engineDescription)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }

                Spacer()

                if !storeManager.isPremium {
                    let remaining = max(0, Self.freeQueryLimit - freeQueryCount)
                    Text(remaining > 0 ? "\(remaining) free left" : "Free limit reached")
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
                        streamingQuery = ""
                        streamingAnswer = ""
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(AppColors.error)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop AI processing")
                    .accessibilityLabel("Stop AI processing")
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

                TutorialHelpButton(showTutorial: $showTutorial)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            .background(AppColors.backgroundPrimary)

            HStack(spacing: Spacing.small) {
                Picker("Engine", selection: $selectedEngine) {
                    Text("Auto").tag(AIEngine.auto)
                    if foundationModelAvailable {
                        Text("Apple AI MoE").tag(AIEngine.appleAIMoE)
                        Text("Apple AI").tag(AIEngine.appleAI)
                        Text("Hybrid").tag(AIEngine.hybrid)
                    }
                    #if !OFFLINE_MODE
                    if cloudAIAvailable {
                        Text("Cloud AI").tag(AIEngine.cloudAI)
                    }
                    #endif
                    Text("NLP").tag(AIEngine.nlp)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Divider().frame(height: 16)

                Picker("Scope", selection: $emailScope) {
                    Text("All (\(emailCount(for: .all)))").tag(EmailScope.all)
                    Text("Filtered (\(emailCount(for: .filtered)))").tag(EmailScope.filtered)
                    Text("Selected (\(emailCount(for: .selected)))").tag(EmailScope.selected)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()

                Label("\(emailCount(for: emailScope)) emails", systemImage: "envelope")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall)
            .background(AppColors.backgroundSecondary.opacity(0.4))
            #endif
        }
    }

    @ViewBuilder
    private var aiHeaderIcon: some View {
        if #available(macOS 26, iOS 26, *) {
            Image(systemName: "apple.intelligence")
                .font(.title2)
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        } else {
            Image(systemName: "sparkles")
                .font(.title2)
                .adaptiveIconGradient(colors: [.purple, .blue, .indigo])
        }
    }

    private var engineDescription: String {
        switch selectedEngine {
        case .auto: return "Smart routing — picks the best engine for each query automatically"
        case .appleAIMoE: return "Apple AI with Mixture of Experts — maximum intelligence, on-device"
        case .appleAI: return "Direct Apple AI — fast single-session, on-device"
        case .hybrid: return "Enhanced NLP + Apple AI synthesis — best of both, on-device"
        #if !OFFLINE_MODE
        case .cloudAI:
            let mgr = CloudAIManager.shared
            return "\(mgr.selectedProvider.displayName) (\(mgr.selectedModel)) — cloud-powered analysis"
        #endif
        case .nlp: return "Pure NLP — fast semantic search + deterministic analysis, no AI needed"
        }
    }

    private func emailCount(for scope: EmailScope) -> Int {
        scopeCounts[scope] ?? 0
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
                            chatBubble(query: item.query, answer: item.answer, timestamp: item.timestamp, relatedEmailIDs: item.relatedEmailIDs, bubbleIndex: index)
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
                Text(engineDescription)
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
            #if os(iOS)
            .frame(maxWidth: .infinity)
            #else
            .frame(maxWidth: 420)
            #endif

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

    private func chatBubble(query: String, answer: String, timestamp: Date? = nil, isStreaming: Bool = false, relatedEmailIDs: [UUID] = [], bubbleIndex: Int = 0) -> some View {
        VStack(spacing: Spacing.small) {
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

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xxSmall) {
                        Image(systemName: "sparkles")
                            .font(Typography.caption1)
                            .foregroundStyle(
                                LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
                            )
                        Text(selectedEngine.rawValue)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                        if isStreaming {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                        Spacer()
                        if !isStreaming && !answer.isEmpty && answer != "Thinking..." {
                            Button {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(answer, forType: .string)
                                #else
                                UIPasteboard.general.string = answer
                                #endif
                                showActionToast = "Copied!"
                                Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1500000000)
                                    if showActionToast == "Copied!" { showActionToast = nil }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                    Text("Copy")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Copy response")
                            .accessibilityLabel("Copy AI response")

                            // v3.2.1: Feedback buttons
                            Button {
                                if #available(macOS 26, iOS 26, *) {
                                    Task {
                                        let intent = await FoundationModelEngine.classifyIntent(query)
                                        FoundationModelEngine.recordUserFeedback(query: query, intent: intent, isPositive: true)
                                    }
                                }
                                showActionToast = "Thanks for the feedback!"
                                Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1500000000)
                                    if showActionToast == "Thanks for the feedback!" { showActionToast = nil }
                                }
                            } label: {
                                Image(systemName: "hand.thumbsup")
                                    .font(.system(size: 11))
                                    .foregroundColor(.green)
                                    .padding(3)
                                    .background(Color.green.opacity(0.08))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Good answer")

                            Button {
                                if #available(macOS 26, iOS 26, *) {
                                    Task {
                                        let intent = await FoundationModelEngine.classifyIntent(query)
                                        FoundationModelEngine.recordUserFeedback(query: query, intent: intent, isPositive: false)
                                    }
                                }
                                showActionToast = "We'll improve!"
                                Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1500000000)
                                    if showActionToast == "We'll improve!" { showActionToast = nil }
                                }
                            } label: {
                                Image(systemName: "hand.thumbsdown")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                    .padding(3)
                                    .background(Color.orange.opacity(0.08))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Needs improvement")

                            // "Show Sources" — surfaces the verifiable
                            // AIProvenance for this answer (which experts
                            // ran, what emails were retrieved, which KG
                            // nodes were cited, reproducibility hashes).
                            Button {
                                showProvenanceSheet = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.shield")
                                        .font(.system(size: 11))
                                    Text("Sources")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.08))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Show what produced this answer — experts, emails, knowledge-graph nodes, and reproducibility hashes")
                            .accessibilityLabel("Show sources for AI answer")
                        }
                    }
                    .accessibilityHidden(true)
                    renderedMarkdown(answer, isStreaming: isStreaming, relatedEmailIDs: relatedEmailIDs)
                        .contextMenu {
                            Button {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(answer, forType: .string)
                                #else
                                UIPasteboard.general.string = answer
                                #endif
                                showActionToast = "Copied!"
                                Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1500000000)
                                    if showActionToast == "Copied!" { showActionToast = nil }
                                }
                            } label: {
                                Label("Copy Response", systemImage: "doc.on.doc")
                            }
                        }

                    if !isStreaming && !relatedEmailIDs.isEmpty {
                        relatedEmailCards(ids: relatedEmailIDs, bubbleIndex: bubbleIndex, answerText: answer)
                    }

                    if let ts = timestamp, !isStreaming {
                        Text(Self.chatTimestampFormatter.string(from: ts))
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary.opacity(0.6))
                    }
                }
                Spacer(minLength: Spacing.xxLarge)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = showActionToast {
                Text(toast)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.xxSmall)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 4)
            }
        }
    }

    @State private var expandedResultSet: Set<Int> = []
    @State private var showActionToast: String?
    @State private var showProvenanceSheet: Bool = false
    @ObservedObject private var provenanceStore = AIProvenanceStore.shared

    private func renderedMarkdown(_ text: String, isStreaming: Bool, relatedEmailIDs: [UUID] = []) -> some View {
        let relatedEmails = relatedEmailIDs.compactMap { cachedEmail(id: $0) }
        let lines = text.components(separatedBy: "\n")
        let lineEmailMap = buildLineEmailMap(lines: lines, emails: relatedEmails)
        let numberedRefs = detectNumberedEmailRefs(text: text, emails: relatedEmails)
        let hasLineLinks = !lineEmailMap.isEmpty

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 6)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        if let attributed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attributed)
                        } else {
                            Text(line)
                        }

                        if let email = lineEmailMap[index] {
                            inlineEmailLink(email: email)
                        }
                    }
                }
            }

            if !numberedRefs.isEmpty && !hasLineLinks {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(numberedRefs.enumerated()), id: \.offset) { _, pair in
                        Button {
                            onSelectEmail?(pair.email.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "envelope.open.fill")
                                    .font(.system(size: 9))
                                Text("\(pair.label): \(pair.email.headers["Subject"] ?? pair.email.headers["subject"] ?? "(No Subject)")")
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 8))
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(pair.label): \(pair.email.headers["Subject"] ?? "email")")
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(Typography.body)
        .textSelection(.enabled)
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.xSmall)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.large)
        .opacity(isStreaming && text == "Thinking..." ? 0.5 : 1.0)
        .accessibilityLabel(isStreaming ? "AI is thinking" : "AI response")
    }

    private func inlineEmailLink(email: MBOXParser.RawEmail) -> some View {
        Button {
            onSelectEmail?(email.id)
            dismiss()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 9))
                Text("Open this email")
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open email: \(email.headers["Subject"] ?? email.headers["subject"] ?? "email")")
    }

    private struct NumberedEmailRef {
        let label: String
        let email: MBOXParser.RawEmail
    }

    private func detectNumberedEmailRefs(text: String, emails: [MBOXParser.RawEmail]) -> [NumberedEmailRef] {
        guard !emails.isEmpty else { return [] }
        var results: [NumberedEmailRef] = []
        var matched: Set<Int> = []

        let patterns = [
            "\\b[Ee]mail\\s+(\\d+)\\b",
            "\\b[Ee]mail\\s*#(\\d+)\\b",
            "\\b[Mm]essage\\s+(\\d+)\\b"
        ]
        let nsText = text as NSString
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            let hits = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for hit in hits {
                if let range = Range(hit.range(at: 1), in: text),
                   let num = Int(text[range]),
                   num >= 1 && num <= emails.count && !matched.contains(num) {
                    results.append(NumberedEmailRef(label: "Email \(num)", email: emails[num - 1]))
                    matched.insert(num)
                }
            }
        }

        if results.isEmpty && emails.count <= 5 {
            let textLower = text.lowercased()
            let ordinals = ["first", "second", "third", "fourth", "fifth"]
            for (i, ordinal) in ordinals.prefix(emails.count).enumerated() where !matched.contains(i + 1) {
                if textLower.contains("\(ordinal) email") || textLower.contains("\(ordinal) message") {
                    results.append(NumberedEmailRef(label: "\(ordinal.capitalized) email", email: emails[i]))
                    matched.insert(i + 1)
                }
            }
        }

        return results
    }

    private func buildLineEmailMap(lines: [String], emails: [MBOXParser.RawEmail]) -> [Int: MBOXParser.RawEmail] {
        guard !emails.isEmpty else { return [:] }
        var map: [Int: MBOXParser.RawEmail] = [:]
        var linked: Set<UUID> = []
        for (index, line) in lines.enumerated() {
            let lineLower = line.lowercased()
            for email in emails where !linked.contains(email.id) {
                let subject = (email.headers["Subject"] ?? email.headers["subject"] ?? "").lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if subject.count > 5 && lineLower.contains(subject) {
                    map[index] = email
                    linked.insert(email.id)
                    break
                }
                if subject.count > 15 {
                    let shortSubject = String(subject.prefix(30))
                    if lineLower.contains(shortSubject) {
                        map[index] = email
                        linked.insert(email.id)
                        break
                    }
                }
                let from = (email.headers["From"] ?? email.headers["from"] ?? "").lowercased()
                let senderName = from.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if senderName.count > 3 && subject.count > 5 {
                    let subjectWords = subject.components(separatedBy: .whitespaces).filter { $0.count > 3 }
                    let matchCount = subjectWords.filter { lineLower.contains($0) }.count
                    if matchCount >= 3 && lineLower.contains(senderName) {
                        map[index] = email
                        linked.insert(email.id)
                        break
                    }
                }
            }
        }
        return map
    }

    private func relatedEmailCards(ids: [UUID], bubbleIndex: Int = 0, answerText: String = "") -> some View {
        let allMatched = ids.compactMap { cachedEmail(id: $0) }
        let answerLower = answerText.lowercased()
        let referenced = allMatched.filter { email in
            let subj = (email.headers["Subject"] ?? email.headers["subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? email.headers["from"] ?? "").lowercased()
            let msgID = (email.headers["Message-ID"] ?? email.headers["message-id"] ?? "").lowercased()
            return (!subj.isEmpty && answerLower.contains(subj)) ||
                   (!from.isEmpty && answerLower.contains(from)) ||
                   (!msgID.isEmpty && answerLower.contains(msgID))
        }
        let matchedEmails = referenced.isEmpty ? allMatched : referenced
        let isExpanded = expandedResultSet.contains(bubbleIndex)
        let displayEmails = isExpanded ? matchedEmails : Array(matchedEmails.prefix(5))

        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xxSmall) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.secondary)
                Text("\(matchedEmails.count) related email\(matchedEmails.count == 1 ? "" : "s") — tap to open")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.secondary)
                Spacer()
                if matchedEmails.count > 5 {
                    Button {
                        withAnimation(AnimationTiming.fast) {
                            if isExpanded { expandedResultSet.remove(bubbleIndex) }
                            else { expandedResultSet.insert(bubbleIndex) }
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "Show all \(matchedEmails.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Spacing.xxSmall)

            ForEach(displayEmails, id: \.id) { email in
                Button {
                    onSelectEmail?(email.id)
                    dismiss()
                } label: {
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(email.headers["Subject"] ?? email.headers["subject"] ?? "(No Subject)")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? email.headers["from"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown")
                                    .font(.system(size: 10))
                                    .foregroundColor(AppColors.secondary)
                                    .lineLimit(1)
                                if !email.timestamp.isEmpty {
                                    Text("·")
                                        .font(.system(size: 10))
                                        .foregroundColor(AppColors.secondary.opacity(0.5))
                                    Text(Self.formatShortDate(email.timestamp))
                                        .font(.system(size: 10))
                                        .foregroundColor(AppColors.secondary.opacity(0.7))
                                }
                            }
                            if !email.plainBody.isEmpty {
                                Text(email.plainBody.prefix(80).replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 10))
                                    .foregroundColor(AppColors.secondary.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(AppColors.secondary.opacity(0.5))
                    }
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, Spacing.xxxSmall)
                    .background(AppColors.backgroundPrimary)
                    .cornerRadius(CornerRadius.small)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.small)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open email: \(email.headers["Subject"] ?? email.headers["subject"] ?? "No Subject")")
            }

            emailActionToolbar(emails: matchedEmails, answerText: answerText)
        }
    }

    private func emailActionToolbar(emails: [MBOXParser.RawEmail], answerText: String = "") -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xSmall) {
                actionButton("Copy Answer", icon: "doc.on.clipboard") {
                    PlatformClipboard.copyString(answerText)
                    showToast("Answer copied")
                }

                Divider().frame(height: 16)

                actionButton("Copy Subjects", icon: "doc.on.doc") {
                    let subjects = emails.map { $0.headers["Subject"] ?? $0.headers["subject"] ?? "(No Subject)" }
                    PlatformClipboard.copyString(subjects.joined(separator: "\n"))
                    showToast("Copied \(subjects.count) subjects")
                }
                actionButton("Copy Senders", icon: "person.2") {
                    let senders = Set(emails.compactMap { $0.headers["From"] ?? $0.headers["from"] })
                    PlatformClipboard.copyString(senders.sorted().joined(separator: "\n"))
                    showToast("Copied \(senders.count) senders")
                }
                actionButton("Copy Bodies", icon: "doc.plaintext") {
                    let bodies = emails.map { email in
                        let subj = email.headers["Subject"] ?? email.headers["subject"] ?? ""
                        let from = email.headers["From"] ?? email.headers["from"] ?? ""
                        return "--- \(subj) (from: \(from)) ---\n\(email.plainBody)"
                    }
                    PlatformClipboard.copyString(bodies.joined(separator: "\n\n"))
                    showToast("Copied \(emails.count) emails")
                }

                Divider().frame(height: 16)

                actionButton("Export CSV", icon: "tablecells") {
                    exportEmailsAsCSV(emails)
                }
                actionButton("Export JSON", icon: "curlybraces") {
                    exportEmailsAsJSON(emails)
                }
                actionButton("Export EML", icon: "envelope") {
                    exportEmailsAsEML(emails)
                }

                Divider().frame(height: 16)

                actionButton("Filter These", icon: "line.3.horizontal.decrease.circle") {
                    let ids = emails.map(\.id)
                    onFilterByIDs?(ids)
                    dismiss()
                }
                actionButton("Tag Relevant", icon: "tag") {
                    for email in emails {
                        forensicManager.tag(email.id, as: .relevant)
                    }
                    showToast("Tagged \(emails.count) as relevant")
                }
                actionButton("Tag Flagged", icon: "flag") {
                    for email in emails {
                        forensicManager.tag(email.id, as: .flagged)
                    }
                    showToast("Flagged \(emails.count) emails")
                }
            }
            .padding(.top, Spacing.xxSmall)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.blue)
                .padding(.horizontal, Spacing.xSmall)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(CornerRadius.small)
        }
        .buttonStyle(.plain)
    }

    private func showToast(_ message: String) {
        withAnimation(AnimationTiming.fast) { showActionToast = message }
        Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2000000000)
            withAnimation(AnimationTiming.fast) { showActionToast = nil }
        }
    }

    private static func formatShortDate(_ raw: String) -> String {
        if let date = MBOXParser.parseDate(raw) {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d, yyyy"
            return fmt.string(from: date)
        }
        return String(raw.prefix(11))
    }

    private func exportEmailsAsCSV(_ emails: [MBOXParser.RawEmail]) {
        var csv = "From,To,Subject,Date,Body\n"
        for email in emails {
            let from = (email.headers["From"] ?? email.headers["from"] ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let to = (email.headers["To"] ?? email.headers["to"] ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let subj = (email.headers["Subject"] ?? email.headers["subject"] ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let body = String(email.plainBody.prefix(500)).replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ")
            csv += "\"\(from)\",\"\(to)\",\"\(subj)\",\"\(email.timestamp)\",\"\(body)\"\n"
        }
        #if os(macOS)
        if let url = PlatformFileSaver.savePanel(suggestedName: "ai_search_results.csv", allowedTypes: [.commaSeparatedText]) {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                showToast("Exported \(emails.count) emails as CSV")
            } catch {
                showToast("CSV export failed: \(error.localizedDescription)")
            }
        }
        #else
        PlatformClipboard.copyString(csv)
        showToast("CSV copied to clipboard")
        #endif
    }

    private func exportEmailsAsJSON(_ emails: [MBOXParser.RawEmail]) {
        let items = emails.map { email -> [String: String] in
            ["from": email.headers["From"] ?? email.headers["from"] ?? "",
             "to": email.headers["To"] ?? email.headers["to"] ?? "",
             "subject": email.headers["Subject"] ?? email.headers["subject"] ?? "",
             "date": email.timestamp,
             "body": email.plainBody]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            showToast("JSON export failed: the results could not be serialized.")
            return
        }
        #if os(macOS)
        if let url = PlatformFileSaver.savePanel(suggestedName: "ai_search_results.json", allowedTypes: [.json]) {
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                showToast("Exported \(emails.count) emails as JSON")
            } catch {
                showToast("JSON export failed: \(error.localizedDescription)")
            }
        }
        #else
        PlatformClipboard.copyString(json)
        showToast("JSON copied to clipboard")
        #endif
    }

    private func exportEmailsAsEML(_ emails: [MBOXParser.RawEmail]) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var count = 0
        var failed = 0
        for email in emails {
            let subj = (email.headers["Subject"] ?? email.headers["subject"] ?? "email")
                .replacingOccurrences(of: "/", with: "_").prefix(50)
            let filename = "\(subj)_\(count).eml"
            let url = folder.appendingPathComponent(String(filename))
            do { try email.rawSource.write(to: url, atomically: true, encoding: .utf8); count += 1 }
            catch { failed += 1 }
        }
        showToast(failed == 0 ? "Exported \(count) EML files"
                              : "Exported \(count) EML files — \(failed) FAILED to write")
        #else
        PlatformClipboard.copyString(emails.map(\.rawSource).joined(separator: "\n\n"))
        showToast("EML content copied to clipboard")
        #endif
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

            HStack {
                if !conversationHistory.isEmpty {
                    Button {
                        let text = conversationHistory.map { item in
                            "Q: \(item.query)\n\nA: \(item.answer)"
                        }.joined(separator: "\n\n---\n\n")
                        PlatformClipboard.copyString(text)
                    } label: {
                        Label("Copy Conversation", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("AI can make mistakes. Always verify important information.")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.secondary.opacity(0.5))
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, 6)
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
        let count = emailCount(for: emailScope)
        let suffix = count == 1 ? "" : "s"
        switch selectedEngine {
        case .auto:
            let resolved = resolveAutoEngine(query: prompt, emailCount: count)
            return "Auto-routed to \(resolved.rawValue) — analyzing \(count) email\(suffix)"
        case .appleAIMoE:
            return "Analyzing \(count) email\(suffix) with Apple AI MoE — full expert pipeline (on-device)"
        case .appleAI:
            return "Analyzing \(count) email\(suffix) with Apple Intelligence (on-device)"
        case .hybrid:
            return "Analyzing \(count) email\(suffix) with Hybrid NLP + AI (on-device)"
        #if !OFFLINE_MODE
        case .cloudAI:
            let mgr = CloudAIManager.shared
            return "Analyzing \(count) email\(suffix) with \(mgr.selectedProvider.displayName) (\(mgr.selectedModel))"
        #endif
        case .nlp:
            return "Analyzing \(count) email\(suffix) with pure NLP engine (on-device)"
        }
    }

    private var engineHelp: String {
        switch selectedEngine {
        case .auto: return "Auto — smart routing picks the best engine based on query complexity, email count, and available resources"
        case .appleAIMoE: return "Apple AI MoE — multi-session experts, fan-in synthesis, self-correction"
        case .appleAI: return "Apple AI — direct single-session, fast and private"
        case .hybrid: return "Hybrid — NLP foundation + RAG + MoE experts + cloud experts + dynamic fan-in synthesis"
        #if !OFFLINE_MODE
        case .cloudAI: return "Cloud AI — \(CloudAIManager.shared.selectedProvider.displayName) powered analysis with NLP + RAG"
        #endif
        case .nlp: return "NLP — pure semantic search + deterministic analysis, no AI"
        }
    }

    // MARK: - Auto-Routing Logic

    private func resolveAutoEngine(query: String, emailCount: Int) -> AIEngine {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAppleAI = foundationModelAvailable
        let hasCloudAI = cloudAIAvailable

        let isComplex = q.count > 80
            || q.contains("compare") || q.contains("investigate")
            || q.contains("analyze") || q.contains("pattern")
            || q.contains("timeline") || q.contains("relationship")
            || q.contains("security") || q.contains("phishing")

        let isSimple = q.split(separator: " ").count <= 4
            || q.contains("count") || q.contains("how many")
            || q.contains("list") || q.contains("show")
            || q.contains("find") || q.contains("search")

        // Complex queries with many emails → Hybrid (best quality, uses cloud experts when available)
        if isComplex && hasAppleAI && emailCount > 10 {
            return .hybrid
        }

        // Complex but no Apple AI → Cloud AI if available, else NLP
        if isComplex && !hasAppleAI {
            #if !OFFLINE_MODE
            if hasCloudAI { return .cloudAI }
            #endif
            return .nlp
        }

        // Medium complexity or moderate email count → Apple AI MoE if available
        if hasAppleAI && emailCount > 50 {
            return .appleAIMoE
        }

        // Quick questions with Apple AI → Direct (fast)
        if isSimple && hasAppleAI {
            return .appleAI
        }

        #if !OFFLINE_MODE
        // Simple with cloud → Cloud AI
        if hasCloudAI {
            return .cloudAI
        }
        #endif

        // Apple AI available → Direct
        if hasAppleAI {
            return .appleAI
        }

        // Fallback
        return .nlp
    }

    // MARK: - AI Logic

    private enum ConversationalIntent {
        case greeting
        case acknowledgment
        case notConversational
    }

    nonisolated private static func classifyConversational(_ query: String) -> ConversationalIntent {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split(separator: " ").map(String.init)

        let emailSignals: Set<String> = [
            "email", "emails", "mail", "mails", "inbox", "message", "messages",
            "from", "to", "sent", "received", "subject", "attachment", "attachments",
            "find", "search", "show", "list", "filter", "sort",
            "phishing", "scam", "spam", "suspicious", "security", "pii",
            "summarize", "summary", "analyze", "analysis", "analytics",
            "sentiment", "tone", "topic", "topics", "trend", "trends",
            "who", "when", "where", "how many", "count", "total",
            "compare", "export", "print", "timeline", "thread",
            "category", "classify", "tag", "label",
            "between", "during", "before", "after", "last week", "last month",
            "reply", "forward", "cc", "bcc", "header",
            "@", "gmail", "outlook", "yahoo",
        ]

        if words.count <= 4 {
            let hasEmailSignal = words.contains { word in
                emailSignals.contains(word) || word.contains("@")
            }
            if !hasEmailSignal {
                let greetingWords: Set<String> = [
                    "hello", "hi", "hey", "howdy", "yo", "sup", "greetings",
                    "hola", "hii", "hiii", "heya", "heyy",
                ]
                let capabilityPhrases = [
                    "what can you do", "what you can do", "what do you do",
                    "how can you help", "help me", "capabilities", "features",
                    "what can i ask", "how do you work", "what are you",
                ]
                if greetingWords.contains(words.first ?? "") ||
                    lower.hasPrefix("how are") || lower.hasPrefix("how r u") ||
                    lower.hasPrefix("good morning") || lower.hasPrefix("good afternoon") ||
                    lower.hasPrefix("good evening") || lower.hasPrefix("what's up") ||
                    lower.hasPrefix("whats up") ||
                    capabilityPhrases.contains(where: { lower.hasPrefix($0) }) {
                    return .greeting
                }

                let ackWords: Set<String> = [
                    "good", "ok", "okay", "cool", "nice", "great", "awesome",
                    "perfect", "thanks", "thank", "thx", "ty", "noted", "sure",
                    "fine", "right", "alright", "understood", "yep", "yup", "yes",
                    "no", "nope", "nah", "lol", "haha", "hmm", "wow", "oh",
                    "interesting", "neat", "sweet", "amazing", "brilliant",
                    "wonderful", "excellent", "fantastic", "superb", "cheers",
                ]
                if words.count <= 3 && words.allSatisfy({ ackWords.contains($0) || $0.count <= 2 }) {
                    return .acknowledgment
                }
            }
        }

        return .notConversational
    }

    // MARK: - Smart Query Handlers
    // Deterministic handlers for common queries — faster and more accurate than LLM for these tasks.
    // Apple's on-device model has only 4096 tokens; rule-based handlers avoid wasting context.

    typealias SmartQueryResult = (query: String, answer: String, timestamp: Date, relatedEmailIDs: [UUID])
    typealias SmartHandler = @Sendable ([MBOXParser.RawEmail]) async -> SmartQueryResult

    nonisolated private static func handleSmartQuery(query: String) -> SmartHandler? {
        let lower = query.lowercased()

        // Duplicate detection
        let dupKeywords = ["duplicate", "duplicates", "duplicated", "dedup", "same email", "same emails", "repeated email", "identical email", "copies of"]
        if dupKeywords.contains(where: { lower.contains($0) }) {
            return { emails in await smartDuplicate(query: query, emails: emails) }
        }

        // Statistics / counts
        let statKeywords = ["how many email", "total email", "email count", "count of email", "number of email", "how many mail", "how many message"]
        if statKeywords.contains(where: { lower.contains($0) }) {
            return { emails in smartStatistics(query: query, emails: emails) }
        }

        // Top senders
        let senderKeywords = ["who emails me", "who sends me", "top sender", "most email", "most frequent sender", "who contacts me", "who messages me"]
        if senderKeywords.contains(where: { lower.contains($0) }) {
            return { emails in smartTopSenders(query: query, emails: emails) }
        }

        // Phishing / security scan
        let securityKeywords = ["phishing", "scan for scam", "check for scam", "suspicious email", "is this phishing", "security scan", "scan for phishing", "check phishing"]
        if securityKeywords.contains(where: { lower.contains($0) }) {
            return { emails in smartPhishingScan(query: query, emails: emails) }
        }

        // Sentiment overview
        let sentimentKeywords = ["sentiment overview", "overall sentiment", "overall tone", "what's the tone", "what is the tone", "mood of my email", "how positive", "how negative", "sentiment analysis", "sentiment of all", "analyze sentiment"]
        if sentimentKeywords.contains(where: { lower.contains($0) }) {
            return { emails in smartSentimentOverview(query: query, emails: emails) }
        }

        // Attachment stats
        let attachKeywords = ["how many attachment", "attachment count", "emails with attachment", "which emails have attachment", "list attachment", "show attachment"]
        if attachKeywords.contains(where: { lower.contains($0) }) {
            return { emails in smartAttachments(query: query, emails: emails) }
        }

        // Date range / timeline
        let dateKeywords = ["date range", "oldest email", "newest email", "first email", "last email", "when was the first", "when was the last", "email timeline"]
        if dateKeywords.contains(where: { lower.contains($0) }) {
            return { emails in smartDateRange(query: query, emails: emails) }
        }

        return nil
    }

    nonisolated private static func smartDuplicate(query: String, emails: [MBOXParser.RawEmail]) async -> SmartQueryResult {
        let exactGroups = await Task.detached(priority: .utility) {
            DuplicateManagerView.findExactDuplicates(in: emails)
        }.value
        let totalDuplicates = exactGroups.reduce(0) { $0 + $1.count - 1 }
        var answer: String
        if exactGroups.isEmpty {
            answer = "**No duplicates found.** All \(emails.count) emails are unique.\n\n"
            answer += "Checked by **Message-ID** and **From+Subject+Date+body** fingerprint."
        } else {
            answer = "**Found \(totalDuplicates) duplicate\(totalDuplicates == 1 ? "" : "s")** in \(exactGroups.count) group\(exactGroups.count == 1 ? "" : "s"):\n\n"
            for (i, group) in exactGroups.prefix(10).enumerated() {
                let subject = group.first?.headers["Subject"] ?? "(No Subject)"
                let from = group.first?.headers["From"] ?? "Unknown"
                answer += "\(i + 1). **\(subject)** from \(from) — \(group.count) copies\n"
            }
            if exactGroups.count > 10 { answer += "\n...and \(exactGroups.count - 10) more groups.\n" }
            answer += "\nUse **Duplicate Manager** (toolbar) to review and remove them."
        }
        let relatedIDs = Array(exactGroups.prefix(3).flatMap { $0.map(\.id) }.prefix(5))
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: relatedIDs)
    }

    nonisolated private static func smartStatistics(query: String, emails: [MBOXParser.RawEmail]) -> SmartQueryResult {
        let sent = emails.filter { $0.messageType == "sent" }.count
        let received = emails.filter { $0.messageType == "received" }.count
        let withAttachments = emails.filter { !$0.attachments.isEmpty }.count
        let uniqueSenders = Set(emails.compactMap { $0.headers["From"] }).count
        let uniqueDomains = Set(emails.flatMap(\.domains)).count
        let answer = """
            **Email Archive Statistics:**

            - **Total emails:** \(emails.count)
            - **Sent:** \(sent) | **Received:** \(received)
            - **With attachments:** \(withAttachments)
            - **Unique senders:** \(uniqueSenders)
            - **Unique domains:** \(uniqueDomains)
            """
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: [])
    }

    nonisolated private static func smartTopSenders(query: String, emails: [MBOXParser.RawEmail]) -> SmartQueryResult {
        var senderCounts: [String: Int] = [:]
        for email in emails {
            let from = email.headers["From"] ?? "Unknown"
            senderCounts[from, default: 0] += 1
        }
        let sorted = senderCounts.sorted { $0.value > $1.value }
        var answer = "**Top Senders** (out of \(Set(senderCounts.keys).count) unique):\n\n"
        for (i, entry) in sorted.prefix(15).enumerated() {
            let pct = emails.isEmpty ? 0 : Int(Double(entry.value) / Double(emails.count) * 100)
            answer += "\(i + 1). **\(entry.key)** — \(entry.value) email\(entry.value == 1 ? "" : "s") (\(pct)%)\n"
        }
        if sorted.count > 15 { answer += "\n...and \(sorted.count - 15) more senders." }
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: [])
    }

    nonisolated private static func smartPhishingScan(query: String, emails: [MBOXParser.RawEmail]) -> SmartQueryResult {
        let phishing = EmailNLPEngine.detectPhishing(in: emails)
        let high = phishing.filter { $0.riskLevel == .high }
        let medium = phishing.filter { $0.riskLevel == .medium }
        var answer: String
        if high.isEmpty && medium.isEmpty {
            answer = "**Security scan complete — no phishing detected.**\n\n"
            answer += "Scanned \(emails.count) emails. No high or medium risk emails found."
        } else {
            answer = "**Security Scan Results:**\n\n"
            answer += "- 🔴 **High risk:** \(high.count) email\(high.count == 1 ? "" : "s")\n"
            answer += "- 🟡 **Medium risk:** \(medium.count) email\(medium.count == 1 ? "" : "s")\n\n"
            if !high.isEmpty {
                answer += "**High-risk emails:**\n"
                for (i, flag) in high.prefix(10).enumerated() {
                    let subject = flag.email.headers["Subject"] ?? "(No Subject)"
                    let from = flag.email.headers["From"] ?? "Unknown"
                    let reasons = flag.reasons.prefix(2).joined(separator: ", ")
                    answer += "\(i + 1). **\(subject)** from \(from) — \(reasons)\n"
                }
            }
        }
        let relatedIDs = Array(high.prefix(5).map(\.email.id))
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: relatedIDs)
    }

    nonisolated private static func smartSentimentOverview(query: String, emails: [MBOXParser.RawEmail]) -> SmartQueryResult {
        let results = EmailNLPEngine.analyzeSentiment(of: emails)
        var positive = 0, negative = 0, neutral = 0
        for r in results {
            if r.score > 0.4 { positive += 1 }
            else if r.score < -0.4 { negative += 1 }
            else { neutral += 1 }
        }
        let avgScore = results.isEmpty ? 0.0 : results.map(\.score).reduce(0, +) / Double(results.count)
        let overallTone = avgScore > 0.4 ? "Positive" : avgScore < -0.4 ? "Negative" : "Neutral"
        let topNeg = results.filter { $0.score < -0.4 }.sorted { $0.score < $1.score }.prefix(5)
        var answer = "**Sentiment Analysis of \(emails.count) emails:**\n\n"
        answer += "- Overall tone: **\(overallTone)** (avg score: \(String(format: "%.2f", avgScore)))\n"
        answer += "- ✅ Positive: **\(positive)** (\(emails.isEmpty ? 0 : positive * 100 / emails.count)%)\n"
        answer += "- ⚪ Neutral: **\(neutral)** (\(emails.isEmpty ? 0 : neutral * 100 / emails.count)%)\n"
        answer += "- ❌ Negative: **\(negative)** (\(emails.isEmpty ? 0 : negative * 100 / emails.count)%)\n"
        if !topNeg.isEmpty {
            answer += "\n**Most negative emails:**\n"
            for (i, r) in topNeg.enumerated() {
                let subject = r.email.headers["Subject"] ?? "(No Subject)"
                answer += "\(i + 1). **\(subject)** (score: \(String(format: "%.2f", r.score)))\n"
            }
        }
        let relatedIDs = Array(topNeg.map(\.email.id))
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: relatedIDs)
    }

    nonisolated private static func smartAttachments(query: String, emails: [MBOXParser.RawEmail]) -> SmartQueryResult {
        let withAttach = emails.filter { !$0.attachments.isEmpty }
        var typeCounts: [String: Int] = [:]
        for email in withAttach {
            for att in email.attachments {
                let ext = (att.filename as NSString).pathExtension.lowercased()
                typeCounts[ext.isEmpty ? "unknown" : ext, default: 0] += 1
            }
        }
        let totalAttachments = emails.flatMap(\.attachments).count
        var answer = "**Attachment Summary:**\n\n"
        answer += "- **\(withAttach.count)** of \(emails.count) emails have attachments (\(totalAttachments) total files)\n\n"
        if !typeCounts.isEmpty {
            answer += "**By type:**\n"
            for (ext, count) in typeCounts.sorted(by: { $0.value > $1.value }).prefix(10) {
                answer += "- .\(ext): \(count) file\(count == 1 ? "" : "s")\n"
            }
        }
        let relatedIDs = Array(withAttach.prefix(5).map(\.id))
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: relatedIDs)
    }

    nonisolated private static func smartDateRange(query: String, emails: [MBOXParser.RawEmail]) -> SmartQueryResult {
        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .short
        var answer: String
        if let first = dates.first, let last = dates.last {
            let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
            answer = "**Email Timeline:**\n\n"
            answer += "- **Oldest:** \(fmt.string(from: first))\n"
            answer += "- **Newest:** \(fmt.string(from: last))\n"
            answer += "- **Span:** \(days) days\n"
            answer += "- **Total:** \(emails.count) emails\n"
            if days > 0 {
                let perDay = Double(emails.count) / Double(days)
                answer += "- **Average:** \(String(format: "%.1f", perDay)) emails/day"
            }
        } else {
            answer = "No parseable dates found in the email headers."
        }
        return (query: query, answer: answer, timestamp: Date(), relatedEmailIDs: [])
    }

    nonisolated private static func generateAppleAIConversationalResponse(_ query: String, emailCount: Int, enabled: Bool) async -> String? {
        guard enabled else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return await FoundationModelEngine.generateConversationalResponse(query, emailCount: emailCount)
        }
        #endif
        return nil
    }

    private func askAI() {
        let query = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        switch Self.classifyConversational(query) {
        case .greeting:
            prompt = ""
            let totalCount = emailCount(for: emailScope)
            currentTask = Task {
                let ws = await currentWorkingSet()
                let sent = ws.filter { $0.messageType == "sent" }.count
                let received = ws.filter { $0.messageType == "received" }.count
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((
                        query: query,
                        answer: "Hello! I'm your email assistant. You have **\(max(totalCount, ws.count)) emails** loaded (\(sent) sent, \(received) received in the working set).\n\nI can help you with:\n- **Search**: \"Find emails about budget\" or \"emails from Sarah\"\n- **Analytics**: \"Who emails me most?\" or \"What topics come up?\"\n- **Sentiment**: \"What's the tone of my emails?\"\n- **Security**: \"Scan for phishing\" or \"Check for sensitive data\"\n- **Summary**: \"Give me a full overview\"\n\nWhat would you like to know?",
                        timestamp: Date(),
                        relatedEmailIDs: []
                    ))
                }
            }
            return
        case .acknowledgment:
            prompt = ""
            withAnimation(AnimationTiming.normal) {
                conversationHistory.append((
                    query: query,
                    answer: "Glad to help! Feel free to ask anything about your emails — search, analytics, security scans, or summaries.",
                    timestamp: Date(),
                    relatedEmailIDs: []
                ))
            }
            return
        case .notConversational:
            break
        }

        if let smartResult = Self.handleSmartQuery(query: query) {
            prompt = ""
            isProcessing = true
            currentTask = Task {
                defer { isProcessing = false }
                let emailsCopy = await currentWorkingSet()
                let result = await smartResult(emailsCopy)
                await MainActor.run {
                    withAnimation(AnimationTiming.normal) {
                        conversationHistory.append(result)
                    }
                }
            }
            return
        }

        if !storeManager.isPremium && freeQueryCount >= Self.freeQueryLimit {
            showUpgradePaywall = true
            return
        }

        currentTask?.cancel()
        isProcessing = true
        let currentQuery = query
        prompt = ""

        let context = searchContext
        let rawEngine = selectedEngine
        let engine: AIEngine = rawEngine == .auto
            ? resolveAutoEngine(query: currentQuery, emailCount: emailCount(for: emailScope))
            : rawEngine

        switch engine {
        // ━━━ Engine 1: Apple AI MoE ━━━
        // Full multi-session expert pipeline with fan-in, self-correction
        // No NLP, no RAG — pure Apple AI with all MoE tools
        case .appleAIMoE:
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }

                streamingQuery = currentQuery
                streamingAnswer = ""
                let emailsCopy = await currentWorkingSet()
                let retrieved = await Self.retrieveRelevantEmails(query: currentQuery, emails: emailsCopy, priorContext: "", predictions: [:])
                let retrievedIDs = Array(retrieved.prefix(5).map(\.id))
                var answer = await askFoundationModelStreaming(currentQuery)
                guard !Task.isCancelled else { return }

                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                streamingQuery = ""
                streamingAnswer = ""
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date(), relatedEmailIDs: retrievedIDs))
                    if !storeManager.isPremium { freeQueryCount += 1 }
                }
            }

        // ━━━ Engine 2: Apple AI (Direct) ━━━
        // Single-session Apple AI — fast, no multi-session overhead
        case .appleAI:
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }

                streamingQuery = currentQuery
                streamingAnswer = ""
                let emailsCopy = await currentWorkingSet()
                let retrieved = await Self.retrieveRelevantEmails(query: currentQuery, emails: emailsCopy, priorContext: "", predictions: [:])
                let retrievedIDs = Array(retrieved.prefix(5).map(\.id))
                var answer = await askFoundationModelDirect(currentQuery)
                guard !Task.isCancelled else { return }

                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                streamingQuery = ""
                streamingAnswer = ""
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date(), relatedEmailIDs: retrievedIDs))
                    if !storeManager.isPremium { freeQueryCount += 1 }
                }
            }

        // ━━━ Engine 3: Hybrid (Best) ━━━
        // NLP foundation + Agentic RAG + MoE experts + dynamic fan-in + self-correction
        case .hybrid:
            let priorContext = conversationHistory.suffix(3).map { "Q: \($0.query)\nA: \($0.answer)" }.joined(separator: "\n\n")
            let currentPredictions = PredictiveCodingEngine.shared.predictions
            let canUseAppleAI = foundationModelAvailable
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }

                // Layer 1: NLP foundation (deterministic — always runs as safety net)
                let emailsCopy = await currentWorkingSet()
                let enhanced = await Self.enhancedNLPPipeline(
                    query: currentQuery,
                    emails: emailsCopy,
                    priorContext: priorContext,
                    predictions: currentPredictions
                )
                guard !Task.isCancelled else { return }

                var answer = enhanced.answer
                var retrievedIDs = enhanced.retrievedIDs

                // Layers 2-5: Apple AI expert pipeline on top of NLP baseline
                if canUseAppleAI {
                    // Layer 2: Agentic RAG retrieval (parallel with NLP — evidence gathering)
                    let priorIDs = priorRetrievedEmailIDs
                    let ragResult = await Self.agenticRetrieve(query: currentQuery, emails: emailsCopy, priorContext: priorContext, predictions: currentPredictions, priorRetrievedIDs: priorIDs)

                    priorRetrievedEmailIDs.formUnion(ragResult.retrievedEmails.map(\.id))
                    let ragIDs = Array(ragResult.retrievedEmails.prefix(5).map(\.id))
                    for rid in ragIDs where !retrievedIDs.contains(rid) {
                        retrievedIDs.append(rid)
                    }

                    // Layers 3-4: Expert sessions + evidence fusion + dynamic fan-in + synthesis
                    streamingQuery = currentQuery
                    streamingAnswer = ""

                    #if canImport(FoundationModels)
                    if #available(macOS 26, iOS 26, *) {
                        do {
                            let hybridResult = try await withThrowingTaskGroup(of: FoundationModelEngine.HybridExpertResult.self) { group in
                                group.addTask {
                                    try await FoundationModelEngine.hybridExpertSynthesis(
                                        query: currentQuery,
                                        emails: emailsCopy,
                                        ragRetrievedEmails: ragResult.retrievedEmails,
                                        ragKeyChunks: ragResult.keyChunks,
                                        ragTimeline: ragResult.threadTimeline,
                                        ragAnalysis: ragResult.enrichedAnalysis,
                                        ragSteps: ragResult.steps,
                                        nlpBaseline: answer,
                                        allEmailCount: emailsCopy.count
                                    ) { partial in
                                        self.streamingAnswer = partial
                                    }
                                }
                                group.addTask {
                                    try await Task.sleep(for: .seconds(55))
                                    throw TimeoutError()
                                }
                                guard let result = try await group.next() else {
                                    group.cancelAll()
                                    return FoundationModelEngine.HybridExpertResult(answer: answer, intent: .general, totalFindings: 0, highRelevanceCount: 0, layerCount: 0)
                                }
                                group.cancelAll()
                                return result
                            }
                            answer = hybridResult.answer

                            // Layer 5: Self-correction — validate and fill gaps
                            streamingQuery = ""
                            streamingAnswer = ""
                            guard !Task.isCancelled else { return }

                            let validationResult = await FoundationModelEngine.validateAnswer(
                                answer: answer, query: currentQuery, intent: hybridResult.intent
                            )
                            if !validationResult.confident, let gap = validationResult.gap, !gap.isEmpty {
                                let gapTerms = EmailNLPEngine.extractSearchTerms(from: gap)
                                if !gapTerms.isEmpty {
                                    let supplementEmails = await Self.retrieveRelevantEmails(
                                        query: gap, emails: emailsCopy, priorContext: priorContext, predictions: currentPredictions
                                    )
                                    if !supplementEmails.isEmpty {
                                        let supplementContext = supplementEmails.prefix(5).map { e in
                                            let subj = e.headers["Subject"] ?? "(No Subject)"
                                            let from = e.headers["From"] ?? "Unknown"
                                            let body = String((e.plainBody.isEmpty ? e.htmlBody : e.plainBody).prefix(200))
                                            return "- **\(subj)** from \(from): \(body)"
                                        }.joined(separator: "\n")
                                        answer += "\n\n---\n**Additional detail:** \(supplementContext)"
                                    }
                                }
                            }
                        } catch is CancellationError {
                            if !streamingAnswer.isEmpty { answer = streamingAnswer }
                        } catch is TimeoutError {
                            answer = streamingAnswer.isEmpty ? answer : streamingAnswer + "\n\n(Expert pipeline timed out — showing partial result)"
                        } catch {
                            // AI failed entirely — NLP answer from Layer 1 is the fallback
                        }
                    }
                    #endif

                    streamingQuery = ""
                    streamingAnswer = ""
                }

                // Part E: mandatory grounding — validate citations against the
                // evidence that was actually retrieved for this turn.
                let gateEvidence = (try? await ArchiveEvidenceService.shared.evidence(ids: retrievedIDs)) ?? []
                answer = AIGroundingGate.ground(answer: answer, evidence: gateEvidence, abstainWhenNoEvidence: false).answer

                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date(), relatedEmailIDs: retrievedIDs))
                    if !storeManager.isPremium { freeQueryCount += 1 }
                }
            }

        #if !OFFLINE_MODE
        // ━━━ Engine 4: Cloud AI (Enhanced with NLP + RAG) ━━━
        case .cloudAI:
            let priorCtxCloud = conversationHistory.suffix(3).map { "Q: \($0.query)\nA: \($0.answer)" }.joined(separator: "\n\n")
            let cloudPredictions = PredictiveCodingEngine.shared.predictions
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }

                // Layer 1: NLP baseline (deterministic foundation)
                let emailsCopy = await currentWorkingSet()
                let nlpResult = await Self.enhancedNLPPipeline(
                    query: currentQuery,
                    emails: emailsCopy,
                    priorContext: priorCtxCloud,
                    predictions: cloudPredictions
                )
                guard !Task.isCancelled else { return }

                // Layer 2: RAG retrieval for focused email context
                let retrieved = await Self.retrieveRelevantEmails(
                    query: currentQuery, emails: emailsCopy, priorContext: priorCtxCloud, predictions: cloudPredictions
                )
                let retrievedIDs = Array(retrieved.prefix(10).map(\.id))
                let targetEmails = retrieved.isEmpty ? emailsCopy : Array(retrieved.prefix(15))
                let emailContext = CloudAIManager.buildEmailContext(from: targetEmails, maxEmails: 15)

                // Layer 3: Cloud AI synthesis with NLP + RAG context
                streamingQuery = currentQuery
                streamingAnswer = ""
                var answer: String
                do {
                    answer = try await CloudAIManager.shared.synthesizeWithCloud(
                        query: currentQuery,
                        nlpBaseline: nlpResult.answer,
                        expertFindings: "",
                        ragAnalysis: "",
                        emailContext: emailContext
                    ) { partial in
                        self.streamingAnswer = partial
                    }
                } catch {
                    answer = nlpResult.answer
                    if !answer.contains("error") {
                        answer = "*(Cloud AI unavailable — showing NLP analysis)*\n\n" + answer
                    }
                }
                guard !Task.isCancelled else { return }

                streamingQuery = ""
                streamingAnswer = ""

                // Part E: mandatory grounding for the cloud-synthesized answer.
                let gateEvidence = (try? await ArchiveEvidenceService.shared.evidence(ids: retrievedIDs)) ?? []
                answer = AIGroundingGate.ground(answer: answer, evidence: gateEvidence, abstainWhenNoEvidence: false).answer

                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date(), relatedEmailIDs: retrievedIDs))
                    if !storeManager.isPremium { freeQueryCount += 1 }
                }
            }
        #endif

        // ━━━ Engine: Auto (resolved above, should not reach here) ━━━
        case .auto:
            break

        // ━━━ Engine 5: NLP (Pure) ━━━
        // No Apple AI ever — pure semantic search + deterministic handlers
        case .nlp:
            let priorContext = conversationHistory.suffix(3).map { "Q: \($0.query)\nA: \($0.answer)" }.joined(separator: "\n\n")
            let currentPredictions = PredictiveCodingEngine.shared.predictions
            currentTask = Task {
                defer {
                    isProcessing = false
                    streamingQuery = ""
                    streamingAnswer = ""
                }

                let emailsCopy = await currentWorkingSet()
                let enhanced = await Self.enhancedNLPPipeline(
                    query: currentQuery,
                    emails: emailsCopy,
                    priorContext: priorContext,
                    predictions: currentPredictions
                )
                guard !Task.isCancelled else { return }

                var answer = enhanced.answer
                let retrievedIDs = enhanced.retrievedIDs

                // Part E: even the deterministic NLP path carries verifiable
                // evidence references, gated by the verifier.
                let gateEvidence = (try? await ArchiveEvidenceService.shared.evidence(ids: retrievedIDs)) ?? []
                answer = AIGroundingGate.ground(answer: answer, evidence: gateEvidence, abstainWhenNoEvidence: false).answer

                if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer = "Scoped to search: \"\(context)\" (\(emailsCopy.count) matches)\n\n" + answer
                }
                withAnimation(AnimationTiming.normal) {
                    conversationHistory.append((query: currentQuery, answer: answer, timestamp: Date(), relatedEmailIDs: retrievedIDs))
                    if !storeManager.isPremium { freeQueryCount += 1 }
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

    private func enhancedNLPFallback(_ query: String) async -> String {
        let ws = await currentWorkingSet()
        return await Self.enhancedNLPPipeline(query: query, emails: ws, priorContext: "", predictions: PredictiveCodingEngine.shared.predictions).answer
    }

    private func askFoundationModelStreaming(_ query: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let specialAction = Self.detectSpecialAction(query)
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        switch specialAction {
                        case .triage:
                            // Bounded: engine retrieves its own working set from SQLite.
                            return try await FoundationModelEngine.triageEmails { partial in
                                self.streamingAnswer = partial
                            }
                        case .insights:
                            return try await FoundationModelEngine.generateInsights { partial in
                                self.streamingAnswer = partial
                            }
                        case .securityBrief:
                            return try await FoundationModelEngine.securityBrief { partial in
                                self.streamingAnswer = partial
                            }
                        case .threadStory:
                            return try await FoundationModelEngine.synthesizeThread { partial in
                                self.streamingAnswer = partial
                            }
                        case .general:
                            // Bounded: orchestrator gets query-relevant retrieval from SQLite.
                            return try await FoundationModelEngine.respondSmart(to: query) { partial in
                                self.streamingAnswer = partial
                            } onConfirmAction: { description in
                                await withCheckedContinuation { continuation in
                                    self.pendingActionDescription = description
                                    self.actionConfirmationContinuation = continuation
                                    self.showActionConfirmation = true
                                }
                            }
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(60))
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        return await enhancedNLPFallback(query)
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
                return await enhancedNLPFallback(query)
            } catch {
                return await enhancedNLPFallback(query)
            }
        }
        #endif
        return await enhancedNLPFallback(query)
    }

    private func askFoundationModelDirect(_ query: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        // Bounded: retrieves its own RAG context from SQLite.
                        try await FoundationModelEngine.respondStreaming(to: query) { partial in
                            self.streamingAnswer = partial
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw TimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        return await enhancedNLPFallback(query)
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
                return await enhancedNLPFallback(query)
            } catch {
                return await enhancedNLPFallback(query)
            }
        }
        #endif
        return await enhancedNLPFallback(query)
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
            "smallest", "shortest", "longest", "largest", "fewest", "heaviest", "long",
            "replied", "active", "busiest", "messages",
            "many", "much", "count", "total", "sent", "send", "received",
            "email", "mail", "message",
            "unanswered", "unreplied", "ignored", "no reply", "never replied",
            "forwarded", "forward", "fwd",
            "link", "url", "links", "urls", "http", "click",
            "response time", "reply time", "slow", "fast", "quick",
            "late", "night", "morning", "afternoon", "evening", "midnight", "hour",
            "between", "to",
            "pdf", "image", "photo", "picture", "document", "spreadsheet", "excel", "word",
            "zip", "csv", "ics", "calendar", "invite",
            "compare", "versus", "vs", "difference",
            "habit", "trend", "pattern", "volume", "over time", "monthly", "weekly", "daily",
            "cc", "bcc", "copied", "carbon copy",
            "no subject", "blank subject", "empty subject",
            "newsletter", "unsubscribe", "marketing", "promotional", "promo",
            "out of office", "auto-reply", "autoreply", "automatic reply", "ooo", "vacation",
            "weekend", "saturday", "sunday",
            "money", "dollar", "payment", "invoice", "amount", "price", "cost",
            "deadline", "due", "overdue", "expire", "expiring",
            "group", "distribution", "mass", "bulk",
            "who do i", "who did i",
        ]
        let specificTerms = extraTerms.filter { !handlerKeywords.contains($0.lowercased()) }
        let dateRange = EmailNLPEngine.parseDateRange(from: lower)

        let scopedEmails: [MBOXParser.RawEmail]
        var scopeLabel = ""
        if !specificTerms.isEmpty || dateRange != nil {
            // Pure scan over the BOUNDED working set this function receives
            // (the caller already did FTS retrieval against the archive).
            let results = EmailNLPEngine.searchWithDateFilter(terms: specificTerms, in: emails, dateRange: dateRange, limit: 200)

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
            if result.average > 0.4 { toneDesc = "quite positive" }
            else if result.average > 0.1 { toneDesc = "generally positive" }
            else if result.average > -0.1 { toneDesc = "fairly neutral" }
            else if result.average > -0.4 { toneDesc = "somewhat negative" }
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
            if languages.count == 1, let first = languages.first {
                result += "Your emails are predominantly in **\(first.language)** — virtually all \(first.count) emails are written in this language.\n"
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
            guard let topCat = sorted.first else { return scopeLabel + "I couldn't categorize these emails — there may not be enough content to classify." }
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

            let repliedToIDs = Set(scopedEmails.compactMap { $0.inReplyTo })
            let unansweredHighPriority = high.filter { r in
                guard let msgID = r.email.headers["Message-ID"] ?? r.email.headers["Message-Id"] else { return false }
                return r.email.messageType == "received" && !repliedToIDs.contains(msgID)
            }

            var result = scopeLabel
            if high.isEmpty && medium.isEmpty {
                result += "Everything looks manageable — I didn't find any high or medium priority emails that need your immediate attention.\n"
            } else if high.isEmpty {
                result += "No urgent items, but there are **\(medium.count) medium-priority** email\(medium.count == 1 ? "" : "s") worth reviewing.\n\n"
            } else {
                result += "You have **\(high.count) high-priority** email\(high.count == 1 ? "" : "s") that may need your attention"
                if medium.count > 0 { result += ", plus \(medium.count) at medium priority" }
                if !unansweredHighPriority.isEmpty { result += " — **\(unansweredHighPriority.count) still unanswered**" }
                result += ".\n\n"
            }
            if !high.isEmpty {
                result += "**Needs attention:**\n\n"
                for (i, r) in high.prefix(5).enumerated() {
                    let from = r.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? r.email.headers["From"] ?? "?"
                    let msgID = r.email.headers["Message-ID"] ?? r.email.headers["Message-Id"] ?? ""
                    let isUnanswered = r.email.messageType == "received" && !repliedToIDs.contains(msgID) && !msgID.isEmpty
                    let unansweredTag = isUnanswered ? " ⚠️ *unanswered*" : ""
                    result += "\(i + 1). **\(r.email.headers["Subject"] ?? "(No Subject)")**\(unansweredTag)\n"
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
            if !unansweredHighPriority.isEmpty { result += "\n\nAsk \"unanswered emails\" for a full list of emails you haven't replied to." }
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
                let trend = EmailNLPEngine.threadSentimentTrend(thread.members)
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
                let summary = EmailNLPEngine.summarizeThread(thread.members)
                let trend = EmailNLPEngine.threadSentimentTrend(thread.members)
                result += "\(i + 1). \(summary)"
                result += "   Sentiment trend: \(trend.overallTrend)\n"
                result += String(repeating: "-", count: 40) + "\n\n"
            }
            return result
        }

        // MARK: - Longest / shortest / most words
        if lower.contains("longest") || lower.contains("shortest") || lower.contains("most words") || lower.contains("fewest words") || lower.contains("biggest email") || lower.contains("smallest email") || (lower.contains("long") && lower.contains("email")) {
            let isLongest = !lower.contains("shortest") && !lower.contains("fewest") && !lower.contains("smallest")
            let sorted = scopedEmails.sorted { a, b in
                let aLen = a.plainBody.isEmpty ? a.htmlBody.count : a.plainBody.count
                let bLen = b.plainBody.isEmpty ? b.htmlBody.count : b.plainBody.count
                return isLongest ? aLen > bLen : aLen < bLen
            }
            let top = Array(sorted.prefix(5))
            guard let winner = top.first else { return scopeLabel + "No emails found to analyze." }

            let label = isLongest ? "longest" : "shortest"
            let winnerBody = winner.plainBody.isEmpty ? winner.htmlBody : winner.plainBody
            let winnerChars = winnerBody.count
            let winnerWords = winnerBody.split(separator: " ").count
            let winnerFrom = winner.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            let winnerSubj = winner.headers["Subject"] ?? winner.headers["subject"] ?? "(No Subject)"
            let winnerDate: String = {
                guard let dateStr = winner.headers["Date"], let date = MBOXParser.parseDate(dateStr) else { return "" }
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return formatter.string(from: date)
            }()
            let preview = String(winnerBody.prefix(120)).replacingOccurrences(of: "\n", with: " ")

            var result = scopeLabel
            result += "**\(label.capitalized) email: \"\(winnerSubj)\"** from **\(winnerFrom)**"
            if !winnerDate.isEmpty { result += " (\(winnerDate))" }
            result += "\n"
            result += "\(winnerChars) characters · \(winnerWords) words\n\n"
            if !preview.isEmpty {
                result += "*\"\(preview)...\"*\n\n"
            }

            let maxLen = (top.first.map { ($0.plainBody.isEmpty ? $0.htmlBody : $0.plainBody).count }) ?? 1
            result += "**All emails ranked by length:**\n\n"
            for (i, email) in top.enumerated() {
                let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
                let chars = body.count
                let words = body.split(separator: " ").count
                let subj = email.headers["Subject"] ?? email.headers["subject"] ?? "(No Subject)"
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let barLen = maxLen > 0 ? max(1, Int(Double(chars) / Double(maxLen) * 20)) : 1
                let bar = String(repeating: "█", count: barLen)
                result += "\(i + 1). **\(subj)** — \(chars) chars, \(words) words\n"
                result += "   \(from) \(bar)\n"
            }

            let avgChars = scopedEmails.isEmpty ? 0 : scopedEmails.reduce(0) { $0 + ($1.plainBody.isEmpty ? $1.htmlBody : $1.plainBody).count } / scopedEmails.count
            result += "\nAverage email length across your archive: **\(avgChars) characters**."
            return result
        }

        // MARK: - Most/fewest attachments
        if (lower.contains("most attachment") || lower.contains("biggest attachment") || lower.contains("largest attachment") || lower.contains("heaviest email") || lower.contains("which email has attachment")) {
            let withAttach = scopedEmails.filter { !$0.attachments.isEmpty }
                .sorted { $0.attachments.count > $1.attachments.count }
            let top = Array(withAttach.prefix(5))

            guard let winner = top.first else { return scopeLabel + "None of these emails have attachments." }
            let winnerSubj = winner.headers["Subject"] ?? "(No Subject)"
            let winnerFrom = winner.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"

            var result = scopeLabel
            result += "**Most attachments: \"\(winnerSubj)\"** from **\(winnerFrom)** — \(winner.attachments.count) attachment\(winner.attachments.count == 1 ? "" : "s")\n\n"

            let types = winner.attachments.map { $0.filename.isEmpty ? $0.mimeType : $0.filename }
            result += "Attachments: \(types.joined(separator: ", "))\n\n"

            if top.count > 1 {
                result += "**Emails with most attachments:**\n\n"
                for (i, email) in top.enumerated() {
                    let subj = email.headers["Subject"] ?? "(No Subject)"
                    let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                    let fileTypes = email.attachments.compactMap(\.filename).prefix(3).joined(separator: ", ")
                    result += "\(i + 1). **\(subj)** — \(email.attachments.count) files (\(fileTypes))\n"
                    result += "   From **\(from)**\n"
                }
            }

            let totalWithAttach = scopedEmails.filter { !$0.attachments.isEmpty }.count
            let pct = scopedEmails.isEmpty ? 0 : Int(Double(totalWithAttach) / Double(scopedEmails.count) * 100)
            result += "\n\(totalWithAttach) of \(scopedEmails.count) emails (\(pct)%) have attachments."
            return result
        }

        // MARK: - Most replied-to thread
        if lower.contains("most replied") || lower.contains("most active thread") || lower.contains("busiest thread") || lower.contains("longest thread") || lower.contains("most messages") {
            let threads = ThreadGrouper.group(scopedEmails)
            let sorted = threads.sorted { $0.count > $1.count }
            let top = Array(sorted.prefix(5))

            guard let winner = top.first else { return scopeLabel + "No conversation threads found." }
            var result = scopeLabel
            result += "**Most active thread: \"\(winner.subject)\"** — \(winner.count) messages\n\n"

            let participants = Set(winner.members.compactMap {
                $0.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces)
            })
            result += "Participants: \(participants.joined(separator: ", "))\n"

            if let first = winner.members.first?.headers["Date"].flatMap({ MBOXParser.parseDate($0) }),
               let last = winner.members.last?.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) {
                let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
                result += "Span: \(days) day\(days == 1 ? "" : "s")\n"
            }

            if top.count > 1 {
                result += "\n**Top threads by reply count:**\n\n"
                for (i, thread) in top.enumerated() {
                    let partCount = Set(thread.members.compactMap {
                        $0.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces)
                    }).count
                    let maxCount = max(1, top[0].count)
                    let bar = String(repeating: "█", count: max(1, Int(Double(thread.count) / Double(maxCount) * 15)))
                    result += "\(i + 1). **\(thread.subject)** — \(thread.count) msgs, \(partCount) people \(bar)\n"
                }
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

        // MARK: - Unanswered / unreplied emails
        if lower.contains("unanswered") || lower.contains("unreplied") || lower.contains("no reply") || lower.contains("never replied") || lower.contains("ignored") || (lower.contains("didn't") && lower.contains("reply")) || (lower.contains("not") && lower.contains("respond")) {
            let repliedToIDs = Set(scopedEmails.compactMap { $0.inReplyTo })

            let unanswered = scopedEmails.filter { email in
                guard let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"] else { return false }
                return email.messageType == "received" && !repliedToIDs.contains(msgID)
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            let hasQuestion = unanswered.filter { email in
                let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
                return body.contains("?") || (email.headers["Subject"] ?? "").contains("?")
            }

            var result = scopeLabel
            if unanswered.isEmpty {
                result += "You've replied to everything — no unanswered emails found."
                return result
            }

            result += "Found **\(unanswered.count) email\(unanswered.count == 1 ? "" : "s")** you haven't replied to"
            if !hasQuestion.isEmpty {
                result += " (\(hasQuestion.count) contain questions)"
            }
            result += ".\n\n"

            let toShow = hasQuestion.isEmpty ? unanswered : hasQuestion
            let label = hasQuestion.isEmpty ? "Most recent unanswered" : "Emails with unanswered questions"
            result += "**\(label):**\n\n"
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in toShow.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let preview = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(80)).replacingOccurrences(of: "\n", with: " ")
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** from **\(from)**\n"
                result += "   \(dateStr)"
                if !preview.isEmpty { result += " — *\"\(preview)...\"*" }
                result += "\n\n"
            }
            if unanswered.count > 8 { result += "...and \(unanswered.count - 8) more unanswered emails." }
            return result
        }

        // MARK: - Forwarded emails
        if lower.contains("forwarded") || lower.contains("forward") || lower.contains("fwd") {
            let forwarded = scopedEmails.filter { email in
                let subject = (email.headers["Subject"] ?? "").lowercased()
                return subject.hasPrefix("fwd:") || subject.hasPrefix("fw:") || subject.contains("[fwd") || subject.contains("forwarded")
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if forwarded.isEmpty {
                result += "No forwarded emails found in your archive."
                return result
            }

            let pctForwarded = scopedEmails.count > 0 ? Int(Double(forwarded.count) / Double(scopedEmails.count) * 100) : 0
            result += "Found **\(forwarded.count) forwarded email\(forwarded.count == 1 ? "" : "s")** (\(pctForwarded)% of your archive).\n\n"

            var forwarderCounts: [String: Int] = [:]
            for email in forwarded {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                forwarderCounts[from, default: 0] += 1
            }
            let topForwarders = forwarderCounts.sorted { $0.value > $1.value }.prefix(3)
            if let top = topForwarders.first {
                result += "**\(top.key)** forwards the most (\(top.value) emails).\n\n"
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            result += "**Recent forwards:**\n\n"
            for (i, email) in forwarded.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let subj = (email.headers["Subject"] ?? "(No Subject)").replacingOccurrences(of: "Fwd: ", with: "").replacingOccurrences(of: "FW: ", with: "").replacingOccurrences(of: "Fw: ", with: "")
                result += "\(i + 1). **\(subj)** — forwarded by **\(from)**, \(dateStr)\n"
            }
            if forwarded.count > 8 { result += "\n...and \(forwarded.count - 8) more." }
            return result
        }

        // MARK: - Emails with links/URLs
        if lower.contains("link") || lower.contains("url") || (lower.contains("http") && !lower.contains("phishing")) || lower.contains("click") {
            let urlRegex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+", options: .caseInsensitive)
            var emailsWithLinks: [(email: MBOXParser.RawEmail, linkCount: Int, domains: [String])] = []

            for email in scopedEmails {
                let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
                guard let regex = urlRegex else { continue }
                let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
                if !matches.isEmpty {
                    var domains: [String] = []
                    for match in matches.prefix(10) {
                        if let range = Range(match.range, in: body) {
                            let url = String(body[range])
                            if let host = URLComponents(string: url)?.host {
                                domains.append(host)
                            }
                        }
                    }
                    emailsWithLinks.append((email: email, linkCount: matches.count, domains: domains))
                }
            }

            var result = scopeLabel
            if emailsWithLinks.isEmpty {
                result += "No emails containing links or URLs found."
                return result
            }

            let totalLinks = emailsWithLinks.reduce(0) { $0 + $1.linkCount }
            let pctWithLinks = scopedEmails.count > 0 ? Int(Double(emailsWithLinks.count) / Double(scopedEmails.count) * 100) : 0
            result += "**\(emailsWithLinks.count) email\(emailsWithLinks.count == 1 ? "" : "s")** contain links (\(pctWithLinks)% of your archive), with **\(totalLinks) total URLs** found.\n\n"

            var domainCounts: [String: Int] = [:]
            for entry in emailsWithLinks {
                for domain in entry.domains { domainCounts[domain, default: 0] += 1 }
            }
            let topDomains = domainCounts.sorted { $0.value > $1.value }.prefix(5)
            if !topDomains.isEmpty {
                result += "**Most linked domains:**\n"
                for domain in topDomains {
                    result += "- \(domain.key) (\(domain.value) links)\n"
                }
                result += "\n"
            }

            let sorted = emailsWithLinks.sorted { $0.linkCount > $1.linkCount }
            result += "**Emails with the most links:**\n\n"
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, entry) in sorted.prefix(5).enumerated() {
                let from = entry.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = entry.email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                result += "\(i + 1). **\(entry.email.headers["Subject"] ?? "(No Subject)")** — \(entry.linkCount) links\n"
                result += "   From **\(from)**, \(dateStr)\n"
            }
            result += "\nTip: Ask \"scan for phishing\" to check if any links look suspicious."
            return result
        }

        // MARK: - Emails by time of day
        if lower.contains("late night") || lower.contains("after midnight") || lower.contains("early morning") || lower.contains("after hours") || lower.contains("night email") || lower.contains("night owl") ||
           ((lower.contains("morning") || lower.contains("afternoon") || lower.contains("evening") || lower.contains("night")) && (lower.contains("email") || lower.contains("sent") || lower.contains("mail"))) {
            let calendar = Calendar.current
            var morningEmails: [MBOXParser.RawEmail] = []    // 6-12
            var afternoonEmails: [MBOXParser.RawEmail] = []  // 12-17
            var eveningEmails: [MBOXParser.RawEmail] = []    // 17-22
            var nightEmails: [MBOXParser.RawEmail] = []      // 22-6

            for email in scopedEmails {
                guard let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { continue }
                let hour = calendar.component(.hour, from: date)
                switch hour {
                case 6..<12: morningEmails.append(email)
                case 12..<17: afternoonEmails.append(email)
                case 17..<22: eveningEmails.append(email)
                default: nightEmails.append(email)
                }
            }

            let total = morningEmails.count + afternoonEmails.count + eveningEmails.count + nightEmails.count
            var result = scopeLabel + "Here's when your emails are sent and received:\n\n"

            let periods: [(String, [MBOXParser.RawEmail], String)] = [
                ("Morning (6 AM–12 PM)", morningEmails, "🌅"),
                ("Afternoon (12–5 PM)", afternoonEmails, "☀️"),
                ("Evening (5–10 PM)", eveningEmails, "🌆"),
                ("Night (10 PM–6 AM)", nightEmails, "🌙"),
            ]

            for (name, emails, icon) in periods {
                let pct = total > 0 ? Int(Double(emails.count) / Double(total) * 100) : 0
                let barLen = total > 0 ? max(1, Int(Double(emails.count) / Double(total) * 30)) : 1
                let bar = String(repeating: "█", count: barLen)
                result += "\(icon) **\(name):** \(emails.count) emails (\(pct)%) \(bar)\n"
            }
            result += "\n"

            if lower.contains("late night") || lower.contains("after midnight") || lower.contains("night") || lower.contains("after hours") {
                if nightEmails.isEmpty {
                    result += "No late-night emails found — healthy boundaries!"
                } else {
                    let sorted = nightEmails.sorted { a, b in
                        let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                        let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                        return da > db
                    }
                    let nightSent = nightEmails.filter { $0.messageType == "sent" }.count
                    let nightReceived = nightEmails.count - nightSent
                    result += "**Late-night activity:** \(nightSent) sent, \(nightReceived) received after hours.\n\n"
                    let timeFmt = DateFormatter()
                    timeFmt.dateStyle = .medium
                    timeFmt.timeStyle = .short
                    result += "**Recent night emails:**\n"
                    for (i, email) in sorted.prefix(5).enumerated() {
                        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                        let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { timeFmt.string(from: $0) } ?? ""
                        result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** — \(from), \(dateStr)\n"
                    }
                }
            } else {
                let peakPeriod = periods.max(by: { $0.1.count < $1.1.count })
                if let peak = peakPeriod {
                    result += "Your inbox is busiest in the **\(peak.0.components(separatedBy: " (").first ?? peak.0)**."
                }
            }
            return result
        }

        // MARK: - Response time analysis
        if lower.contains("response time") || lower.contains("reply time") || (lower.contains("how") && lower.contains("fast") && lower.contains("reply")) || (lower.contains("slow") && lower.contains("reply")) || (lower.contains("quick") && lower.contains("reply")) || lower.contains("average reply") || lower.contains("time to respond") {
            let messageIDMap: [String: MBOXParser.RawEmail] = {
                var map: [String: MBOXParser.RawEmail] = [:]
                for email in scopedEmails {
                    if let msgID = email.headers["Message-ID"] ?? email.headers["Message-Id"] {
                        map[msgID] = email
                    }
                }
                return map
            }()

            var contactResponseTimes: [String: [TimeInterval]] = [:]
            var myResponseTimes: [TimeInterval] = []

            for email in scopedEmails {
                guard let replyToID = email.inReplyTo,
                      let originalEmail = messageIDMap[replyToID],
                      let replyDate = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }),
                      let origDate = originalEmail.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { continue }

                let interval = replyDate.timeIntervalSince(origDate)
                guard interval > 0 && interval < 30 * 24 * 3600 else { continue }

                if email.messageType == "sent" {
                    myResponseTimes.append(interval)
                } else {
                    let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? email.headers["From"] ?? "Unknown"
                    contactResponseTimes[from, default: []].append(interval)
                }
            }

            var result = scopeLabel

            if myResponseTimes.isEmpty && contactResponseTimes.isEmpty {
                result += "I can't calculate response times — I need threaded conversations with Message-ID headers to track replies. Your emails may be standalone messages."
                return result
            }

            result += "**Email Response Time Analysis**\n\n"

            if !myResponseTimes.isEmpty {
                let avgMine = myResponseTimes.reduce(0, +) / Double(myResponseTimes.count)
                let medianMine = myResponseTimes.sorted()[myResponseTimes.count / 2]
                result += "**Your response time:** You reply in **\(formatInterval(avgMine))** on average (median: \(formatInterval(medianMine))) based on \(myResponseTimes.count) replies.\n\n"
            }

            if !contactResponseTimes.isEmpty {
                let contactAvgs = contactResponseTimes.map { (name: $0.key, avg: $0.value.reduce(0, +) / Double($0.value.count), count: $0.value.count) }
                    .sorted { $0.avg < $1.avg }

                let fastest = contactAvgs.prefix(3)
                let slowest = contactAvgs.suffix(3).reversed()

                if !fastest.isEmpty {
                    result += "**Fastest to reply:**\n"
                    for (i, c) in fastest.enumerated() {
                        result += "\(i + 1). **\(c.name)** — \(formatInterval(c.avg)) average (\(c.count) replies)\n"
                    }
                    result += "\n"
                }
                if contactAvgs.count > 3 {
                    result += "**Slowest to reply:**\n"
                    for (i, c) in slowest.enumerated() {
                        result += "\(i + 1). **\(c.name)** — \(formatInterval(c.avg)) average (\(c.count) replies)\n"
                    }
                }
            }
            return result
        }

        // MARK: - Emails with specific attachment types (PDF, images, spreadsheets, etc.)
        if (lower.contains("pdf") || lower.contains("image") || lower.contains("photo") || lower.contains("picture") || lower.contains("spreadsheet") || lower.contains("excel") || lower.contains("word") || lower.contains("zip") || lower.contains("csv") || lower.contains("document")) && (lower.contains("email") || lower.contains("attachment") || lower.contains("with") || lower.contains("contain") || lower.contains("have") || lower.contains("find") || lower.contains("show")) {
            let typeMap: [(keywords: [String], extensions: [String], label: String)] = [
                (["pdf"], ["pdf"], "PDF"),
                (["image", "photo", "picture"], ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp"], "image"),
                (["spreadsheet", "excel", "xlsx", "xls"], ["xlsx", "xls", "csv", "numbers"], "spreadsheet"),
                (["word", "doc"], ["doc", "docx", "rtf"], "Word document"),
                (["zip", "archive", "compressed"], ["zip", "gz", "tar", "rar", "7z"], "archive"),
                (["csv"], ["csv"], "CSV"),
                (["calendar", "invite", "ics"], ["ics"], "calendar invite"),
            ]

            var targetExts: [String] = []
            var targetLabel = "matching"
            for (keywords, extensions, label) in typeMap {
                if keywords.contains(where: { lower.contains($0) }) {
                    targetExts.append(contentsOf: extensions)
                    targetLabel = label
                }
            }

            let matched = scopedEmails.filter { email in
                email.attachments.contains { att in
                    let name = att.filename.lowercased()
                    let mimeType = att.mimeType.lowercased()
                    let extMatch = targetExts.contains { name.hasSuffix(".\($0)") }
                    let mimeMatch: Bool
                    if targetLabel == "image" {
                        mimeMatch = mimeType.hasPrefix("image/")
                    } else if targetLabel == "PDF" {
                        mimeMatch = mimeType == "application/pdf"
                    } else {
                        mimeMatch = false
                    }
                    return extMatch || mimeMatch
                }
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if matched.isEmpty {
                result += "No emails with \(targetLabel) attachments found."
                return result
            }

            let totalAttachments = matched.reduce(0) { total, email in
                total + email.attachments.filter { att in
                    let name = att.filename.lowercased()
                    return targetExts.contains { name.hasSuffix(".\($0)") } || (targetLabel == "image" && att.mimeType.lowercased().hasPrefix("image/")) || (targetLabel == "PDF" && att.mimeType.lowercased() == "application/pdf")
                }.count
            }

            result += "Found **\(matched.count) email\(matched.count == 1 ? "" : "s")** with **\(totalAttachments) \(targetLabel) attachment\(totalAttachments == 1 ? "" : "s")**.\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in matched.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let fileNames = email.attachments.filter { att in
                    let name = att.filename.lowercased()
                    return targetExts.contains { name.hasSuffix(".\($0)") } || (targetLabel == "image" && att.mimeType.lowercased().hasPrefix("image/")) || (targetLabel == "PDF" && att.mimeType.lowercased() == "application/pdf")
                }.map(\.filename)
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** — \(from), \(dateStr)\n"
                result += "   📎 \(fileNames.joined(separator: ", "))\n"
            }
            if matched.count > 8 { result += "\n...and \(matched.count - 8) more." }
            return result
        }

        // MARK: - Compare two contacts
        if lower.contains("compare") || lower.contains("versus") || lower.contains(" vs ") || (lower.contains("difference") && lower.contains("between")) {
            let nameTagger = NLTagger(tagSchemes: [.nameType])
            nameTagger.string = query
            var detectedNames: [String] = []
            nameTagger.enumerateTags(in: query.startIndex..<query.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, range in
                if tag == .personalName || tag == .organizationName {
                    detectedNames.append(String(query[range]))
                }
                return true
            }

            if detectedNames.isEmpty {
                let parts = lower.replacingOccurrences(of: "compare", with: "")
                    .replacingOccurrences(of: "versus", with: "and")
                    .replacingOccurrences(of: " vs ", with: " and ")
                    .components(separatedBy: " and ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count > 1 }
                detectedNames = parts
            }

            if detectedNames.count >= 2 {
                let name1 = detectedNames[0]
                let name2 = detectedNames[1]
                let emails1 = EmailNLPEngine.fuzzyMatchContacts(name: name1, in: scopedEmails)
                let emails2 = EmailNLPEngine.fuzzyMatchContacts(name: name2, in: scopedEmails)

                if emails1.isEmpty && emails2.isEmpty {
                    return "I couldn't find emails from either \"\(name1)\" or \"\(name2)\"."
                }

                let displayName1 = emails1.first?.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? name1.capitalized
                let displayName2 = emails2.first?.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? name2.capitalized

                let sent1 = emails1.filter { $0.messageType == "sent" }.count
                let recv1 = emails1.filter { $0.messageType == "received" }.count
                let sent2 = emails2.filter { $0.messageType == "sent" }.count
                let recv2 = emails2.filter { $0.messageType == "received" }.count

                let sentiment1 = EmailNLPEngine.averageSentiment(of: emails1)
                let sentiment2 = EmailNLPEngine.averageSentiment(of: emails2)
                let tone1 = sentiment1.average > 0.1 ? "positive" : sentiment1.average < -0.1 ? "critical" : "neutral"
                let tone2 = sentiment2.average > 0.1 ? "positive" : sentiment2.average < -0.1 ? "critical" : "neutral"

                let dates1 = emails1.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
                let dates2 = emails2.compactMap { MBOXParser.parseDate($0.headers["Date"]) }.sorted()
                let dateFmt = DateFormatter()
                dateFmt.dateStyle = .medium

                let avgLen1 = emails1.isEmpty ? 0 : emails1.reduce(0) { $0 + ($1.plainBody.isEmpty ? $1.htmlBody : $1.plainBody).count } / emails1.count
                let avgLen2 = emails2.isEmpty ? 0 : emails2.reduce(0) { $0 + ($1.plainBody.isEmpty ? $1.htmlBody : $1.plainBody).count } / emails2.count

                var result = scopeLabel + "**\(displayName1)** vs **\(displayName2)**\n\n"
                result += "| | **\(displayName1)** | **\(displayName2)** |\n"
                result += "|---|---|---|\n"
                result += "| Total emails | \(emails1.count) | \(emails2.count) |\n"
                result += "| You sent | \(sent1) | \(sent2) |\n"
                result += "| You received | \(recv1) | \(recv2) |\n"
                result += "| Tone | \(tone1) | \(tone2) |\n"
                result += "| Avg email length | \(avgLen1) chars | \(avgLen2) chars |\n"
                if let first1 = dates1.first { result += "| First email | \(dateFmt.string(from: first1)) |" } else { result += "| First email | — |" }
                if let first2 = dates2.first { result += " \(dateFmt.string(from: first2)) |\n" } else { result += " — |\n" }
                if let last1 = dates1.last { result += "| Last email | \(dateFmt.string(from: last1)) |" } else { result += "| Last email | — |" }
                if let last2 = dates2.last { result += " \(dateFmt.string(from: last2)) |\n" } else { result += " — |\n" }

                let moreActive = emails1.count > emails2.count ? displayName1 : displayName2
                let warmer = sentiment1.average > sentiment2.average ? displayName1 : displayName2
                result += "\n**\(moreActive)** is the more active correspondent. **\(warmer)** has a warmer tone overall."
                return result
            }
        }

        // MARK: - Email volume trends over time
        if lower.contains("habit") || lower.contains("trend") || lower.contains("over time") || lower.contains("volume") || (lower.contains("pattern") && !lower.contains("phishing")) || lower.contains("monthly") || lower.contains("weekly") || lower.contains("daily") {
            let calendar = Calendar.current
            var monthlyVolume: [(month: String, sent: Int, received: Int)] = []
            var monthMap: [String: (sent: Int, received: Int)] = [:]
            let monthFmt = DateFormatter()
            monthFmt.dateFormat = "yyyy-MM"
            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "MMM yyyy"

            for email in scopedEmails {
                guard let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { continue }
                let key = monthFmt.string(from: date)
                var current = monthMap[key] ?? (sent: 0, received: 0)
                if email.messageType == "sent" { current.sent += 1 } else { current.received += 1 }
                monthMap[key] = current
            }

            let sortedMonths = monthMap.keys.sorted()
            for key in sortedMonths {
                if let date = monthFmt.date(from: key), let val = monthMap[key] {
                    monthlyVolume.append((month: displayFmt.string(from: date), sent: val.sent, received: val.received))
                }
            }

            guard !monthlyVolume.isEmpty else { return scopeLabel + "Not enough date data to show trends." }

            var result = scopeLabel + "**Email Volume Trends**\n\n"

            let maxTotal = monthlyVolume.map { $0.sent + $0.received }.max() ?? 1
            for entry in monthlyVolume.suffix(12) {
                let total = entry.sent + entry.received
                let barLen = max(1, Int(Double(total) / Double(maxTotal) * 25))
                let bar = String(repeating: "█", count: barLen)
                result += "\(entry.month.padding(toLength: 8, withPad: " ", startingAt: 0)) \(bar) \(total) (\(entry.sent)↑ \(entry.received)↓)\n"
            }
            result += "\n"

            let totalSent = monthlyVolume.reduce(0) { $0 + $1.sent }
            let totalRecv = monthlyVolume.reduce(0) { $0 + $1.received }
            let avgMonthly = monthlyVolume.isEmpty ? 0 : (totalSent + totalRecv) / monthlyVolume.count
            result += "**Average:** \(avgMonthly) emails/month (\(monthlyVolume.isEmpty ? 0 : totalSent / monthlyVolume.count) sent, \(monthlyVolume.isEmpty ? 0 : totalRecv / monthlyVolume.count) received)\n"

            if monthlyVolume.count >= 3 {
                let recentAvg = monthlyVolume.suffix(3).reduce(0) { $0 + $1.sent + $1.received } / 3
                let olderAvg = monthlyVolume.prefix(max(1, monthlyVolume.count - 3)).reduce(0) { $0 + $1.sent + $1.received } / max(1, monthlyVolume.count - 3)
                if recentAvg > olderAvg + 5 {
                    result += "\n📈 Your email volume has been **increasing** recently."
                } else if recentAvg < olderAvg - 5 {
                    result += "\n📉 Your email volume has been **decreasing** recently."
                } else {
                    result += "\n📊 Your email volume has been **steady**."
                }
            }

            let peakMonth = monthlyVolume.max(by: { ($0.sent + $0.received) < ($1.sent + $1.received) })
            if let peak = peakMonth {
                result += "\n**Peak month:** \(peak.month) with \(peak.sent + peak.received) emails."
            }

            let dayOfWeekCounts = [Int](repeating: 0, count: 8)
            var dowCounts = dayOfWeekCounts
            for email in scopedEmails {
                guard let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { continue }
                let dow = calendar.component(.weekday, from: date)
                dowCounts[dow] += 1
            }
            let weekendCount = dowCounts[1] + dowCounts[7]
            let weekdayCount = (2...6).reduce(0) { $0 + dowCounts[$1] }
            let weekendPct = (weekendCount + weekdayCount) > 0 ? Int(Double(weekendCount) / Double(weekendCount + weekdayCount) * 100) : 0
            result += "\n**Weekend vs weekday:** \(weekendPct)% of emails are on weekends."

            return result
        }

        // MARK: - CC'd / BCC'd emails
        if lower.contains("cc'd") || lower.contains("cc me") || lower.contains("copied on") || lower.contains("carbon copy") || lower.contains("bcc") || (lower.contains("cc") && (lower.contains("email") || lower.contains("mail"))) {
            let ccEmails = scopedEmails.filter { email in
                let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
                return !cc.isEmpty
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if ccEmails.isEmpty {
                result += "No emails with CC recipients found."
                return result
            }

            let pctCC = scopedEmails.count > 0 ? Int(Double(ccEmails.count) / Double(scopedEmails.count) * 100) : 0
            result += "**\(ccEmails.count) email\(ccEmails.count == 1 ? "" : "s")** have CC recipients (\(pctCC)% of your archive).\n\n"

            var ccCounts: [String: Int] = [:]
            for email in ccEmails {
                let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
                for addr in cc.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    let name = addr.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? addr
                    ccCounts[name, default: 0] += 1
                }
            }
            let topCC = ccCounts.sorted { $0.value > $1.value }.prefix(5)
            if !topCC.isEmpty {
                result += "**Most frequently CC'd:**\n"
                for (i, entry) in topCC.enumerated() {
                    result += "\(i + 1). **\(entry.key)** — CC'd on \(entry.value) email\(entry.value == 1 ? "" : "s")\n"
                }
                result += "\n"
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            result += "**Recent CC'd emails:**\n\n"
            for (i, email) in ccEmails.prefix(5).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** — \(from), \(dateStr)\n"
            }
            return result
        }

        // MARK: - Emails with no subject
        if lower.contains("no subject") || lower.contains("blank subject") || lower.contains("empty subject") || lower.contains("without subject") || lower.contains("missing subject") {
            let noSubject = scopedEmails.filter { email in
                let subject = (email.headers["Subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return subject.isEmpty
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if noSubject.isEmpty {
                result += "All emails have subject lines — none are blank."
                return result
            }

            let pct = scopedEmails.count > 0 ? Int(Double(noSubject.count) / Double(scopedEmails.count) * 100) : 0
            result += "Found **\(noSubject.count) email\(noSubject.count == 1 ? "" : "s")** with no subject line (\(pct)% of archive).\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in noSubject.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let preview = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(60)).replacingOccurrences(of: "\n", with: " ")
                result += "\(i + 1). From **\(from)** — \(dateStr)\n"
                if !preview.isEmpty { result += "   *\"\(preview)...\"*\n" }
            }
            if noSubject.count > 8 { result += "\n...and \(noSubject.count - 8) more." }
            return result
        }

        // MARK: - Newsletters / marketing / promotional
        if lower.contains("newsletter") || lower.contains("unsubscribe") || lower.contains("marketing") || lower.contains("promotional") || lower.contains("promo") || lower.contains("mailing list") {
            let newsletters = scopedEmails.filter { email in
                let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
                let from = (email.headers["From"] ?? "").lowercased()
                let listHeader = email.headers["List-Unsubscribe"] ?? email.headers["List-Id"] ?? ""
                return body.contains("unsubscribe") || !listHeader.isEmpty ||
                    from.contains("newsletter") || from.contains("noreply") || from.contains("no-reply") ||
                    from.contains("marketing") || from.contains("news@") || from.contains("updates@")
            }

            var result = scopeLabel
            if newsletters.isEmpty {
                result += "No newsletters or marketing emails detected."
                return result
            }

            let pctNews = scopedEmails.count > 0 ? Int(Double(newsletters.count) / Double(scopedEmails.count) * 100) : 0
            result += "Found **\(newsletters.count) newsletter/marketing email\(newsletters.count == 1 ? "" : "s")** (\(pctNews)% of your archive).\n\n"

            var senderCounts: [String: Int] = [:]
            for email in newsletters {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? email.headers["From"] ?? "Unknown"
                senderCounts[from, default: 0] += 1
            }
            let topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(8)
            result += "**Top newsletter sources:**\n\n"
            for (i, entry) in topSenders.enumerated() {
                result += "\(i + 1). **\(entry.key)** — \(entry.value) email\(entry.value == 1 ? "" : "s")\n"
            }
            if senderCounts.count > 8 { result += "\n...and \(senderCounts.count - 8) more sources." }
            result += "\n\nThese emails make up \(pctNews)% of your archive. Consider unsubscribing from inactive ones to reduce clutter."
            return result
        }

        // MARK: - Out of office / auto-replies
        if lower.contains("out of office") || lower.contains("auto-reply") || lower.contains("autoreply") || lower.contains("automatic reply") || lower.contains("ooo") || lower.contains("vacation reply") {
            let autoReplies = scopedEmails.filter { email in
                let subject = (email.headers["Subject"] ?? "").lowercased()
                let autoSubmitted = (email.headers["Auto-Submitted"] ?? "").lowercased()
                let precedence = (email.headers["Precedence"] ?? "").lowercased()
                return subject.contains("out of office") || subject.contains("automatic reply") ||
                    subject.contains("auto reply") || subject.contains("ooo:") ||
                    subject.contains("vacation") || subject.contains("away from") ||
                    autoSubmitted == "auto-replied" || precedence == "bulk" || precedence == "auto_reply"
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if autoReplies.isEmpty {
                result += "No out-of-office or auto-reply messages found."
                return result
            }

            result += "Found **\(autoReplies.count) auto-reply/out-of-office** message\(autoReplies.count == 1 ? "" : "s").\n\n"

            var senderCounts: [String: Int] = [:]
            for email in autoReplies {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                senderCounts[from, default: 0] += 1
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in autoReplies.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                result += "\(i + 1). **\(from)** — \(dateStr)\n"
                result += "   \(email.headers["Subject"] ?? "(No Subject)")\n"
            }
            if autoReplies.count > 8 { result += "\n...and \(autoReplies.count - 8) more." }
            return result
        }

        // MARK: - Weekend emails
        if lower.contains("weekend") || lower.contains("saturday") || lower.contains("sunday") {
            let calendar = Calendar.current
            let weekendEmails = scopedEmails.filter { email in
                guard let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                let weekday = calendar.component(.weekday, from: date)
                return weekday == 1 || weekday == 7
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if weekendEmails.isEmpty {
                result += "No weekend emails found — looks like weekends are email-free!"
                return result
            }

            let weekdayEmails = scopedEmails.count - weekendEmails.count
            let satCount = weekendEmails.filter { email in
                guard let date = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return false }
                return calendar.component(.weekday, from: date) == 7
            }.count
            let sunCount = weekendEmails.count - satCount
            let sentOnWeekend = weekendEmails.filter { $0.messageType == "sent" }.count
            let pctWeekend = scopedEmails.count > 0 ? Int(Double(weekendEmails.count) / Double(scopedEmails.count) * 100) : 0

            result += "**\(weekendEmails.count) email\(weekendEmails.count == 1 ? "" : "s")** were sent/received on weekends (\(pctWeekend)% of your archive).\n\n"
            result += "- **Saturday:** \(satCount) emails\n"
            result += "- **Sunday:** \(sunCount) emails\n"
            result += "- **You sent** \(sentOnWeekend) emails on weekends\n"
            result += "- **Weekday emails:** \(weekdayEmails)\n\n"

            var weekendSenders: [String: Int] = [:]
            for email in weekendEmails.filter({ $0.messageType == "received" }) {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                weekendSenders[from, default: 0] += 1
            }
            let topWeekendSenders = weekendSenders.sorted { $0.value > $1.value }.prefix(3)
            if !topWeekendSenders.isEmpty {
                result += "**Who emails you on weekends:**\n"
                for (i, entry) in topWeekendSenders.enumerated() {
                    result += "\(i + 1). **\(entry.key)** — \(entry.value) weekend email\(entry.value == 1 ? "" : "s")\n"
                }
            }
            return result
        }

        // MARK: - Emails mentioning money / payments / invoices
        if lower.contains("money") || lower.contains("dollar") || lower.contains("payment") || lower.contains("invoice") || lower.contains("amount") || lower.contains("price") || lower.contains("cost") || lower.contains("bill") || (lower.contains("financial") && !lower.contains("phishing")) {
            let moneyRegex = try? NSRegularExpression(pattern: "\\$[\\d,]+\\.?\\d*|\\d+\\.\\d{2}\\s*(USD|EUR|GBP)|payment|invoice|receipt|billing|refund", options: .caseInsensitive)

            let financialEmails = scopedEmails.filter { email in
                let text = "\(email.headers["Subject"] ?? "") \(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)"
                guard let regex = moneyRegex else { return false }
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if financialEmails.isEmpty {
                result += "No emails mentioning money, payments, or invoices found."
                return result
            }

            result += "Found **\(financialEmails.count) email\(financialEmails.count == 1 ? "" : "s")** with financial content (payments, invoices, amounts).\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in financialEmails.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** — \(from), \(dateStr)\n"
            }
            if financialEmails.count > 8 { result += "\n...and \(financialEmails.count - 8) more." }
            result += "\n\n⚠️ Tip: Ask \"scan for phishing\" to check if any financial emails look suspicious."
            return result
        }

        // MARK: - Deadline / due date emails
        if lower.contains("deadline") || lower.contains("due") || lower.contains("overdue") || lower.contains("expire") || lower.contains("expiring") || lower.contains("due date") {
            let deadlineRegex = try? NSRegularExpression(pattern: "deadline|due date|due by|expires?|expiring|overdue|by end of|no later than|must be submitted|action required by", options: .caseInsensitive)

            let deadlineEmails = scopedEmails.filter { email in
                let text = "\(email.headers["Subject"] ?? "") \(email.plainBody.isEmpty ? email.htmlBody : email.plainBody)"
                guard let regex = deadlineRegex else { return false }
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if deadlineEmails.isEmpty {
                result += "No emails mentioning deadlines or due dates found."
                return result
            }

            result += "Found **\(deadlineEmails.count) email\(deadlineEmails.count == 1 ? "" : "s")** mentioning deadlines or due dates.\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in deadlineEmails.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let preview = String((email.plainBody.isEmpty ? email.htmlBody : email.plainBody).prefix(80)).replacingOccurrences(of: "\n", with: " ")
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** — \(from), \(dateStr)\n"
                if !preview.isEmpty { result += "   *\"\(preview)...\"*\n" }
            }
            if deadlineEmails.count > 8 { result += "\n...and \(deadlineEmails.count - 8) more." }
            result += "\n\nAsk \"show me unanswered emails\" to check if any deadline emails still need a response."
            return result
        }

        // MARK: - Group / mass / bulk emails
        if lower.contains("group email") || lower.contains("mass email") || lower.contains("bulk email") || lower.contains("distribution") || (lower.contains("group") && lower.contains("mail")) {
            let groupEmails = scopedEmails.filter { email in
                let to = email.headers["To"] ?? ""
                let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
                let recipientCount = to.split(separator: ",").count + cc.split(separator: ",").count
                let listHeader = email.headers["List-Id"] ?? email.headers["List-Unsubscribe"] ?? ""
                return recipientCount >= 5 || !listHeader.isEmpty
            }.sorted { a, b in
                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                return da > db
            }

            var result = scopeLabel
            if groupEmails.isEmpty {
                result += "No group or mass emails found (looking for emails with 5+ recipients or mailing list headers)."
                return result
            }

            let pctGroup = scopedEmails.count > 0 ? Int(Double(groupEmails.count) / Double(scopedEmails.count) * 100) : 0
            result += "Found **\(groupEmails.count) group/mass email\(groupEmails.count == 1 ? "" : "s")** (\(pctGroup)% of archive).\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (i, email) in groupEmails.prefix(8).enumerated() {
                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                let to = email.headers["To"] ?? ""
                let cc = email.headers["Cc"] ?? email.headers["CC"] ?? ""
                let recipientCount = to.split(separator: ",").count + cc.split(separator: ",").count
                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")** — \(from), \(dateStr) (\(recipientCount) recipients)\n"
            }
            if groupEmails.count > 8 { result += "\n...and \(groupEmails.count - 8) more." }
            return result
        }

        // MARK: - Who do I email most? (outgoing focus)
        if (lower.contains("who do i") || lower.contains("who did i")) && (lower.contains("email") || lower.contains("write") || lower.contains("send") || lower.contains("mail") || lower.contains("contact")) {
            let sentEmails = scopedEmails.filter { $0.messageType == "sent" }
            var recipientCounts: [String: Int] = [:]
            for email in sentEmails {
                let to = email.headers["To"] ?? ""
                for addr in to.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    let name = addr.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? addr
                    if !name.isEmpty { recipientCounts[name, default: 0] += 1 }
                }
            }

            let topRecipients = recipientCounts.sorted { $0.value > $1.value }.prefix(10)

            var result = scopeLabel
            if topRecipients.isEmpty {
                result += "No sent emails found to analyze your outgoing patterns."
                return result
            }

            result += "**People you email most** (based on \(sentEmails.count) sent emails):\n\n"
            let maxCount = topRecipients.first?.value ?? 1
            for (i, entry) in topRecipients.enumerated() {
                let barLen = max(1, Int(Double(entry.value) / Double(maxCount) * 20))
                let bar = String(repeating: "█", count: barLen)
                result += "\(i + 1). **\(entry.key)** — \(entry.value) email\(entry.value == 1 ? "" : "s") \(bar)\n"
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
            if sentiment.average > 0.4 { toneDesc = "quite positive" }
            else if sentiment.average > 0.1 { toneDesc = "generally positive" }
            else if sentiment.average > -0.1 { toneDesc = "mostly neutral" }
            else if sentiment.average > -0.4 { toneDesc = "somewhat negative" }
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
                let sentiment = EmailNLPEngine.averageSentiment(of: thread.members)
                let trend = EmailNLPEngine.threadSentimentTrend(thread.members)
                let participants = trend.participants.prefix(3).map { "**\($0)**" }.joined(separator: ", ")
                let toneWord = sentiment.average > 0.1 ? "positive" : sentiment.average < -0.1 ? "tense" : "neutral"
                result += "\(i + 1). **\(thread.subject)** — \(thread.count) messages, \(toneWord) tone (\(trend.overallTrend))\n"
                result += "   Between: \(participants)\n\n"
            }
            result += "Ask \"summarize thread\" for detailed summaries, or \"thread sentiment\" to see how the tone evolved in each conversation."
            return result
        }

        // MARK: - Greetings, Capabilities & Acknowledgments
        switch classifyConversational(query) {
        case .greeting:
            let sent = scopedEmails.filter { $0.messageType == "sent" }.count
            let received = scopedEmails.filter { $0.messageType == "received" }.count
            return "Hello! I'm your email assistant. You have **\(scopedEmails.count) emails** loaded (\(sent) sent, \(received) received).\n\nI can help you with:\n- **Search**: \"Find emails about budget\" or \"emails from Sarah\"\n- **Analytics**: \"Who emails me most?\" or \"What topics come up?\"\n- **Sentiment**: \"What's the tone of my emails?\"\n- **Security**: \"Scan for phishing\" or \"Check for sensitive data\"\n- **Summary**: \"Give me a full overview\"\n\nWhat would you like to know?"
        case .acknowledgment:
            return "Glad to help! Feel free to ask anything about your emails — search, analytics, security scans, or summaries."
        case .notConversational:
            break
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
                    guard let latest = sorted.first else { return "No emails found." }
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

        // MARK: - "Show me emails to [person]" or "emails I sent to [person]"
        let toPatterns = ["show me emails to", "show emails to", "emails to", "mail to", "messages to",
                          "find emails to", "emails i sent to", "emails sent to", "what did i send to",
                          "what i sent to", "my emails to"]
        for pattern in toPatterns {
            if lower.hasPrefix(pattern) || lower.contains("sent to") {
                var nameStart: String
                if lower.contains("sent to") {
                    nameStart = lower.components(separatedBy: "sent to").last?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "?", with: "") ?? ""
                } else {
                    nameStart = lower.replacingOccurrences(of: pattern, with: "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "?", with: "")
                }
                if !nameStart.isEmpty {
                    let nameLower = nameStart.lowercased()
                    let contactEmails = scopedEmails.filter { email in
                        let to = (email.headers["To"] ?? "").lowercased()
                        let cc = (email.headers["Cc"] ?? "").lowercased()
                        return to.contains(nameLower) || cc.contains(nameLower)
                    }
                    if !contactEmails.isEmpty {
                        let sorted = contactEmails.sorted { a, b in
                            let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                            let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                            return da > db
                        }
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        var result = "Found **\(contactEmails.count) email\(contactEmails.count == 1 ? "" : "s")** sent to **\(nameStart.capitalized)**:\n\n"
                        for (i, email) in sorted.prefix(10).enumerated() {
                            let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                            let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "You"
                            let hasAttach = email.attachments.isEmpty ? "" : " 📎"
                            result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")**\(hasAttach) — \(dateStr)\n"
                            result += "   From: \(from)\n"
                        }
                        if contactEmails.count > 10 { result += "\n...and \(contactEmails.count - 10) more." }
                        result += "\n\nAsk \"emails from \(nameStart)\" to see what they sent you."
                        return result
                    }
                    return "I couldn't find any emails sent to \"\(nameStart)\". Try \"who emails me most?\" to see your contacts."
                }
                break
            }
        }

        // MARK: - "Emails between X and Y"
        let betweenPatterns = ["emails between", "messages between", "conversation between",
                               "correspondence between", "mail between", "exchange between"]
        for pattern in betweenPatterns {
            if lower.contains(pattern) {
                let rest = lower.components(separatedBy: pattern).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let parts = rest.components(separatedBy: " and ")
                if parts.count == 2 {
                    let name1 = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "?", with: "")
                    let name2 = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "?", with: "")
                    if !name1.isEmpty && !name2.isEmpty {
                        let meKeywords = ["me", "myself", "i"]
                        let isName1Me = meKeywords.contains(name1.lowercased())
                        let isName2Me = meKeywords.contains(name2.lowercased())

                        let matched: [MBOXParser.RawEmail]
                        if isName1Me || isName2Me {
                            let otherName = (isName1Me ? name2 : name1).lowercased()
                            matched = scopedEmails.filter { email in
                                let from = (email.headers["From"] ?? "").lowercased()
                                let to = (email.headers["To"] ?? "").lowercased()
                                let cc = (email.headers["Cc"] ?? "").lowercased()
                                return from.contains(otherName) || to.contains(otherName) || cc.contains(otherName)
                            }
                        } else {
                            let n1 = name1.lowercased()
                            let n2 = name2.lowercased()
                            matched = scopedEmails.filter { email in
                                let all = "\(email.headers["From"] ?? "") \(email.headers["To"] ?? "") \(email.headers["Cc"] ?? "")".lowercased()
                                return all.contains(n1) && all.contains(n2)
                            }
                        }

                        if !matched.isEmpty {
                            let sorted = matched.sorted { a, b in
                                let da = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
                                let db = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
                                return da > db
                            }
                            let formatter = DateFormatter()
                            formatter.dateStyle = .medium
                            let sentiment = EmailNLPEngine.averageSentiment(of: matched)
                            let toneWord = sentiment.average > 0.1 ? "positive" : sentiment.average < -0.1 ? "tense" : "neutral"
                            var result = "Found **\(matched.count) email\(matched.count == 1 ? "" : "s")** between **\(name1.capitalized)** and **\(name2.capitalized)** — overall tone is \(toneWord).\n\n"
                            for (i, email) in sorted.prefix(10).enumerated() {
                                let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
                                let dateStr = email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatter.string(from: $0) } ?? ""
                                let hasAttach = email.attachments.isEmpty ? "" : " 📎"
                                result += "\(i + 1). **\(email.headers["Subject"] ?? "(No Subject)")**\(hasAttach)\n"
                                result += "   \(from) — \(dateStr)\n"
                            }
                            if matched.count > 10 { result += "\n...and \(matched.count - 10) more." }
                            return result
                        }
                        return "I couldn't find any emails between \"\(name1)\" and \"\(name2)\". Check the spelling or try \"who emails me most?\" to see your contacts."
                    }
                }
                break
            }
        }

        // MARK: - "Thank you" / acknowledgements
        if lower.hasPrefix("thank") || lower == "thanks" || lower == "ok" || lower == "okay" || lower == "got it" || lower == "cool" || lower == "great" || lower == "nice" {
            return "You're welcome! Let me know if you'd like to explore anything else about your emails."
        }

        if lower == "help" || lower == "?" || lower.hasPrefix("what can you") || lower.hasPrefix("what do you") {
            return """
            Ask me anything about your emails in natural language! Examples:

            **Search & Find**
            • "Find emails about meetings last month"
            • "Show me emails from Sarah" / "emails to John"
            • "Emails between me and David"
            • "When was the last email from Priya?"

            **Analytics & Insights**
            • "Who emails me most?" / "Give me a full summary"
            • "What topics come up?" / "What's the sentiment?"
            • "Who takes longest to reply?" / "My response time"
            • "Show me late night emails" / "When am I busiest?"

            **Action Items**
            • "Show me unanswered emails"
            • "High priority emails" / "What did I miss?"
            • "Which emails were forwarded?"
            • "Show me emails with links"

            **Security & Privacy**
            • "Scan for phishing" / "Check for sensitive data"

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
            suggestions.append("\"Show me late night emails\" — after-hours activity")
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
        if lower.contains("reply") || lower.contains("respond") || lower.contains("answer") || lower.contains("ignore") {
            suggestions.append("\"Show me unanswered emails\" — emails you haven't replied to")
            suggestions.append("\"Who takes longest to reply?\" — response time analysis")
        }
        if lower.contains("send") || lower.contains("to") || lower.contains("wrote") {
            suggestions.append("\"Emails I sent to [name]\" — your outgoing messages")
            suggestions.append("\"Emails between me and [name]\" — full correspondence")
        }
        if lower.contains("link") || lower.contains("forward") || lower.contains("share") {
            suggestions.append("\"Show me emails with links\" — find URLs in your archive")
            suggestions.append("\"Which emails were forwarded?\" — forwarded messages")
        }
        if suggestions.isEmpty {
            suggestions = [
                "\"Give me a summary\" — full archive overview",
                "\"Show me unanswered emails\" — emails needing replies",
                "\"Who emails me most?\" — see top contacts",
                "\"What's the sentiment?\" — tone analysis",
                "\"Find emails about [topic]\" — search your archive",
                "\"Who takes longest to reply?\" — response times",
            ]
        }
        let suggestionList = suggestions.prefix(5).map { "- \($0)" }.joined(separator: "\n")
        return "I'm not sure I understood that, but I can analyze your \(emails.count) emails in many ways. Try one of these:\n\n\(suggestionList)\n\nOr type **help** to see everything I can do!"
    }

    // MARK: - Enhanced NLP Pipeline (works without Apple AI)

    private struct NLPCachedAnswer {
        let query: String
        let answer: String
        let emailIDs: [UUID]
        let emailCount: Int
        let timestamp: Date
    }

    private nonisolated static let nlpStateQueue = DispatchQueue(label: "com.mailin.nlpState")
    nonisolated(unsafe) private static var _nlpAnswerCache: [NLPCachedAnswer] = []
    nonisolated(unsafe) private static var _nlpPrecomputedSenderProfiles: [(name: String, count: Int, topics: [String], sentiment: String)] = []
    nonisolated(unsafe) private static var _nlpPrecomputedTopicClusters: [(topic: String, count: Int, senders: [String])] = []
    nonisolated(unsafe) private static var _nlpPrecomputedTimeline: [(period: String, count: Int, topSender: String)] = []
    nonisolated(unsafe) private static var _nlpPrecomputationDone = false

    static func nlpPrecomputeOnImport(emails: [MBOXParser.RawEmail]) {
        guard !emails.isEmpty else { return }
        Task.detached(priority: .utility) {
            // Sender profiles
            let senderGroups = Dictionary(grouping: emails, by: { $0.headers["From"] ?? "Unknown" })
            let displayName: (String) -> String = { raw in
                raw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? raw
            }
            var profiles: [(name: String, count: Int, topics: [String], sentiment: String)] = []
            for (sender, senderEmails) in senderGroups.sorted(by: { $0.value.count > $1.value.count }).prefix(20) {
                let topics = EmailNLPEngine.extractTopics(from: senderEmails, limit: 3).map(\.word)
                let sentimentResults = EmailNLPEngine.analyzeSentiment(of: senderEmails)
                let avgSent = sentimentResults.map(\.score).reduce(0, +) / Double(max(sentimentResults.count, 1))
                let tone = avgSent > 0.2 ? "positive" : avgSent < -0.2 ? "negative" : "neutral"
                profiles.append((name: displayName(sender), count: senderEmails.count, topics: topics, sentiment: tone))
            }
            nlpStateQueue.sync { _nlpPrecomputedSenderProfiles = profiles }

            // Topic clusters
            let allTopics = EmailNLPEngine.extractTopics(from: emails, limit: 15)
            var clusters: [(topic: String, count: Int, senders: [String])] = []
            for topic in allTopics {
                let matching = emails.filter { email in
                    let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
                    let subject = (email.headers["Subject"] ?? "").lowercased()
                    return body.contains(topic.word.lowercased()) || subject.contains(topic.word.lowercased())
                }
                let topSenders = Dictionary(grouping: matching, by: { displayName($0.headers["From"] ?? "Unknown") })
                    .sorted { $0.value.count > $1.value.count }
                    .prefix(3).map(\.key)
                clusters.append((topic: topic.word, count: topic.count, senders: topSenders))
            }
            nlpStateQueue.sync { _nlpPrecomputedTopicClusters = clusters }

            // Monthly timeline
            let cal = Calendar.current
            let dateGroups = Dictionary(grouping: emails) { email -> String in
                guard let dateStr = email.headers["Date"],
                      let date = MBOXParser.parseDate(dateStr) else { return "Unknown" }
                let comps = cal.dateComponents([.year, .month], from: date)
                guard let y = comps.year, let m = comps.month else { return "Unknown" }
                return "\(y)-\(String(format: "%02d", m))"
            }
            var timeline: [(period: String, count: Int, topSender: String)] = []
            for (period, periodEmails) in dateGroups.sorted(by: { $0.key > $1.key }).prefix(12) {
                guard period != "Unknown" else { continue }
                let topSender = Dictionary(grouping: periodEmails, by: { displayName($0.headers["From"] ?? "Unknown") })
                    .sorted { $0.value.count > $1.value.count }
                    .first?.key ?? "Unknown"
                timeline.append((period: period, count: periodEmails.count, topSender: topSender))
            }
            nlpStateQueue.sync {
                _nlpPrecomputedTimeline = timeline
                _nlpPrecomputationDone = true
            }
        }
    }

    static func invalidateNLPCache() {
        nlpStateQueue.sync { _nlpAnswerCache.removeAll() }
    }

    static func invalidateNLPPrecomputation() {
        nlpStateQueue.sync {
            _nlpPrecomputedSenderProfiles.removeAll()
            _nlpPrecomputedTopicClusters.removeAll()
            _nlpPrecomputedTimeline.removeAll()
            _nlpPrecomputationDone = false
        }
    }

    nonisolated private static func checkNLPCache(query: String, emailCount: Int) -> NLPCachedAnswer? {
        let cacheCopy = nlpStateQueue.sync { _nlpAnswerCache }

        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return cacheCopy.first { $0.query.lowercased() == query.lowercased() && $0.emailCount == emailCount }
        }
        let queryWords = query.lowercased().split(separator: " ").map(String.init)
        var bestMatch: (answer: NLPCachedAnswer, similarity: Double)?
        for cached in cacheCopy {
            guard cached.emailCount == emailCount else { continue }
            if abs(cached.timestamp.timeIntervalSinceNow) > 600 { continue }
            let cachedWords = cached.query.lowercased().split(separator: " ").map(String.init)
            var totalSim = 0.0
            var count = 0
            for qw in queryWords {
                for cw in cachedWords {
                    let sim = embedding.distance(between: qw, and: cw)
                    totalSim += (1.0 - sim)
                    count += 1
                }
            }
            let avgSim = count > 0 ? totalSim / Double(count) : 0
            if avgSim > 0.75 {
                if bestMatch.map({ avgSim > $0.similarity }) ?? true {
                    bestMatch = (cached, avgSim)
                }
            }
        }
        return bestMatch?.answer
    }

    nonisolated private static func cacheNLPAnswer(query: String, answer: String, emailIDs: [UUID], emailCount: Int) {
        let entry = NLPCachedAnswer(query: query, answer: answer, emailIDs: emailIDs, emailCount: emailCount, timestamp: Date())
        nlpStateQueue.sync {
            _nlpAnswerCache.removeAll { abs($0.timestamp.timeIntervalSinceNow) > 600 }
            _nlpAnswerCache.append(entry)
            if _nlpAnswerCache.count > 50 {
                _nlpAnswerCache.removeFirst(_nlpAnswerCache.count - 50)
            }
        }
    }

    nonisolated private static func enrichWithChunkEvidence(answer: String, query: String, emails: [MBOXParser.RawEmail]) -> (enriched: String, evidenceIDs: [UUID]) {
        let searchTerms = EmailNLPEngine.extractSearchTerms(from: query.lowercased())
        guard !searchTerms.isEmpty else { return (answer, []) }

        let chunkResults = ArchiveEvidenceService.chunkExcerpts(terms: searchTerms, in: emails, maxChunksPerEmail: 1, limit: 5)
        guard !chunkResults.isEmpty else { return (answer, []) }

        let displayName: (String?) -> String = { raw in
            guard let raw else { return "someone" }
            return raw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? raw
        }

        var evidence = "\n\n---\n**Key excerpts from your emails:**\n"
        var evidenceIDs: [UUID] = []
        for result in chunkResults.prefix(3) {
            let from = displayName(result.email.headers["From"])
            let subject = result.email.headers["Subject"] ?? "(No Subject)"
            let snippet = String(result.chunk.prefix(250)).trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty { continue }
            evidence += "\n> **\(from)** — \"\(subject)\"\n> \"\(snippet)...\"\n"
            evidenceIDs.append(result.email.id)
        }

        return (answer + evidence, evidenceIDs)
    }

    nonisolated private static func enrichWithPrecomputedContext(answer: String, query: String) -> String {
        let (done, senderProfiles, topicClusters, timeline) = nlpStateQueue.sync {
            (_nlpPrecomputationDone, _nlpPrecomputedSenderProfiles, _nlpPrecomputedTopicClusters, _nlpPrecomputedTimeline)
        }

        guard done else { return answer }
        let lower = query.lowercased()

        var enrichment = ""

        let wantsSenderInfo = lower.contains("who") || lower.contains("sender") || lower.contains("from") || lower.contains("contact") || lower.contains("person")
        let wantsTopics = lower.contains("topic") || lower.contains("about") || lower.contains("theme") || lower.contains("subject")
        let wantsTimeline = lower.contains("when") || lower.contains("time") || lower.contains("trend") || lower.contains("month") || lower.contains("history")

        if wantsSenderInfo && !senderProfiles.isEmpty {
            let relevant = senderProfiles.prefix(5)
            let profileStrings = relevant.map { p in
                var s = "**\(p.name)** (\(p.count) emails, \(p.sentiment) tone)"
                if !p.topics.isEmpty { s += " — topics: \(p.topics.joined(separator: ", "))" }
                return s
            }
            enrichment += "\n\n**Top contacts in your archive:**\n" + profileStrings.map { "- \($0)" }.joined(separator: "\n")
        }

        if wantsTopics && !topicClusters.isEmpty {
            let relevant = topicClusters.prefix(5)
            let topicStrings = relevant.map { t in
                var s = "**\(t.topic)** (\(t.count) mentions)"
                if !t.senders.isEmpty { s += " — from \(t.senders.joined(separator: ", "))" }
                return s
            }
            enrichment += "\n\n**Key topics across your archive:**\n" + topicStrings.map { "- \($0)" }.joined(separator: "\n")
        }

        if wantsTimeline && !timeline.isEmpty {
            let relevant = timeline.prefix(6)
            let timeStrings = relevant.map { "\($0.period): \($0.count) emails (top sender: \($0.topSender))" }
            enrichment += "\n\n**Activity timeline:**\n" + timeStrings.map { "- \($0)" }.joined(separator: "\n")
        }

        guard !enrichment.isEmpty else { return answer }
        return answer + enrichment
    }

    nonisolated private static func nlpSaidNoResults(_ answer: String) -> Bool {
        let phrases = [
            "no emails", "couldn't find", "could not find", "didn't find",
            "no results", "nothing matching", "0 emails", "zero emails",
            "not sure i understood", "i looked through all"
        ]
        let lower = answer.lowercased()
        return phrases.contains { lower.contains($0) }
    }

    nonisolated private static func isLongNumberedList(_ answer: String) -> Bool {
        let lines = answer.components(separatedBy: "\n")
        let numberedLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
        return numberedLines.count >= 8
    }

    nonisolated private static func synthesizeFromRetrievedEmails(query: String, emails: [MBOXParser.RawEmail]) -> String {
        guard !emails.isEmpty else { return "" }

        let displayName: (String?) -> String = { raw in
            guard let raw else { return "someone" }
            return raw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? raw
        }

        let senderGroups = Dictionary(grouping: emails, by: { displayName($0.headers["From"]) })
            .sorted { $0.value.count > $1.value.count }

        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium

        let dateResults = emails.compactMap { email -> (MBOXParser.RawEmail, Date)? in
            guard let d = email.headers["Date"].flatMap({ MBOXParser.parseDate($0) }) else { return nil }
            return (email, d)
        }.sorted { $0.1 > $1.1 }

        // Group subjects into clusters by normalized form
        let subjects = emails.compactMap { $0.headers["Subject"] }
        let cleanSubjects = subjects.map { $0.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") }
        let subjectGroups = Dictionary(grouping: cleanSubjects, by: { $0 }).sorted { $0.value.count > $1.value.count }

        // Determine what the emails are actually about
        let topics = EmailNLPEngine.extractTopics(from: emails, limit: 5)
        let topicPhrase = topics.isEmpty ? "various topics" : topics.prefix(3).map { "**\($0.word)**" }.joined(separator: ", ")

        var response = "I found **\(emails.count) email\(emails.count == 1 ? "" : "s")** related to your query, covering \(topicPhrase).\n\n"

        // Grouped by conversation thread / subject
        if subjectGroups.count == 1, let only = subjectGroups.first {
            let sender = senderGroups.first.map { $0.key } ?? "someone"
            response += "They're all part of the same conversation: \"\(only.key)\" — primarily from **\(sender)**.\n\n"
        } else if !subjectGroups.isEmpty {
            response += "**Conversations:**\n"
            for group in subjectGroups.prefix(4) {
                let groupEmails = emails.filter {
                    ($0.headers["Subject"] ?? "").replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") == group.key
                }
                let groupSenders = Set(groupEmails.map { displayName($0.headers["From"]) })
                let senderStr = groupSenders.prefix(2).joined(separator: ", ")
                response += "- \"\(group.key)\" — \(group.value.count) email\(group.value.count == 1 ? "" : "s") from \(senderStr)\n"
            }
            if subjectGroups.count > 4 {
                response += "- ...and \(subjectGroups.count - 4) other conversation\(subjectGroups.count - 4 == 1 ? "" : "s")\n"
            }
            response += "\n"
        }

        // Sender breakdown (only if multiple)
        if senderGroups.count > 1 {
            let topSenders = senderGroups.prefix(3)
            let senderStr = topSenders.map { "**\($0.key)** (\($0.value.count))" }.joined(separator: ", ")
            response += "**Key people:** \(senderStr)"
            if senderGroups.count > 3 { response += ", and \(senderGroups.count - 3) others" }
            response += "\n\n"
        }

        // Time context
        if let earliest = dateResults.last, let latest = dateResults.first {
            if earliest.1 == latest.1 || Calendar.current.isDate(earliest.1, inSameDayAs: latest.1) {
                response += "These are from **\(dateFmt.string(from: latest.1))**.\n\n"
            } else {
                response += "Spanning **\(dateFmt.string(from: earliest.1))** to **\(dateFmt.string(from: latest.1))**.\n\n"
            }
        }

        // Sentiment snapshot
        let sentiment = EmailNLPEngine.analyzeSentiment(of: emails)
        let avg = sentiment.map(\.score).reduce(0, +) / Double(max(sentiment.count, 1))
        let tone = avg > 0.3 ? "positive and friendly" : avg > 0.1 ? "generally positive" : avg < -0.3 ? "concerned or urgent" : avg < -0.1 ? "somewhat serious" : "professional and neutral"
        response += "Overall tone: **\(tone)**.\n\n"

        // Content preview — show the most relevant excerpt
        if let latest = dateResults.first {
            let from = displayName(latest.0.headers["From"])
            let subject = latest.0.headers["Subject"] ?? "(No Subject)"
            let body = latest.0.plainBody.isEmpty ? latest.0.htmlBody : latest.0.plainBody
            let cleanBody = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let snippet = String(cleanBody.prefix(250)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty {
                response += "**Latest** from **\(from)** — \"\(subject)\":\n> \"\(snippet)...\"\n"
            }
        }

        return response
    }

    nonisolated private static func condenseLongList(_ answer: String, query: String, emails: [MBOXParser.RawEmail]) -> String {
        let lines = answer.components(separatedBy: "\n")
        var headerLines: [String] = []
        var numberedItems: [String] = []
        var footerLines: [String] = []
        var seenNumbered = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                seenNumbered = true
                numberedItems.append(line)
            } else if !seenNumbered {
                headerLines.append(line)
            } else {
                footerLines.append(line)
            }
        }

        let header = headerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let footer = footerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Search for the actual matching emails to analyze
        let searchTerms = EmailNLPEngine.extractSearchTerms(from: query.lowercased())
        let matchedEmails = EmailNLPEngine.searchEmails(terms: searchTerms, in: emails, limit: max(numberedItems.count, 30))
        let matchedRaw = matchedEmails.map(\.email)

        let displayName: (String?) -> String = { raw in
            guard let raw else { return "someone" }
            return raw.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? raw
        }

        var condensed = ""
        if !header.isEmpty { condensed += header + "\n\n" }

        // Group by subject/topic cluster instead of raw list
        let subjects = matchedRaw.compactMap { $0.headers["Subject"] }
            .map { $0.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") }
        let subjectGroups = Dictionary(grouping: subjects, by: { $0 }).sorted { $0.value.count > $1.value.count }
        let senderGroups = Dictionary(grouping: matchedRaw, by: { $0.headers["From"] ?? "Unknown" })
            .sorted { $0.value.count > $1.value.count }

        // Narrative summary
        if !subjectGroups.isEmpty {
            condensed += "**Grouped by conversation** (\(numberedItems.count) emails total):\n\n"
            for group in subjectGroups.prefix(5) {
                let groupEmails = matchedRaw.filter {
                    ($0.headers["Subject"] ?? "").replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") == group.key
                }
                let groupSenders = Array(Set(groupEmails.map { displayName($0.headers["From"]) }))
                let senderStr = groupSenders.prefix(2).joined(separator: ", ")
                let dates = groupEmails.compactMap { $0.headers["Date"].flatMap { MBOXParser.parseDate($0) } }
                let dateFmt = DateFormatter()
                dateFmt.dateStyle = .short

                condensed += "- **\"\(group.key)\"** — \(group.value.count) email\(group.value.count == 1 ? "" : "s")"
                condensed += " from \(senderStr)"
                if let latest = dates.max() { condensed += " (latest: \(dateFmt.string(from: latest)))" }
                condensed += "\n"
            }
            if subjectGroups.count > 5 {
                let remaining = subjectGroups.dropFirst(5).map(\.value.count).reduce(0, +)
                condensed += "- ...and **\(remaining) more** across \(subjectGroups.count - 5) other threads\n"
            }
        }

        // Key senders
        condensed += "\n**Top senders:**\n"
        for sender in senderGroups.prefix(3) {
            let name = displayName(sender.key)
            let senderTopics = Set(sender.value.compactMap { $0.headers["Subject"] }
                .map { $0.replacingOccurrences(of: "Re: ", with: "").replacingOccurrences(of: "Fwd: ", with: "") })
            let topicStr = senderTopics.prefix(2).joined(separator: ", ")
            condensed += "- **\(name)** — \(sender.value.count) email\(sender.value.count == 1 ? "" : "s")"
            if !topicStr.isEmpty { condensed += " about \(topicStr)" }
            condensed += "\n"
        }

        // Sentiment + time range
        let sentiment = EmailNLPEngine.analyzeSentiment(of: matchedRaw)
        let avg = sentiment.map(\.score).reduce(0, +) / Double(max(sentiment.count, 1))
        let tone = avg > 0.2 ? "positive" : avg < -0.2 ? "concerned/urgent" : "neutral"

        let allDates = matchedRaw.compactMap { $0.headers["Date"].flatMap { MBOXParser.parseDate($0) } }.sorted()
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        if let first = allDates.first, let last = allDates.last {
            condensed += "\n**Period:** \(dateFmt.string(from: first)) — \(dateFmt.string(from: last)) | **Tone:** \(tone)\n"
        } else {
            condensed += "\n**Tone:** \(tone)\n"
        }

        if !footer.isEmpty { condensed += "\n" + footer }

        return condensed
    }

    nonisolated private static func isStructuredQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        let structuredPatterns: [String] = [
            "how many", "how much", "count", "total number",
            "phishing", "scam", "suspicious", "spam", "fraud",
            "pii", "gdpr", "compliance", "sensitive data", "privacy",
            "classify", "categorize", "category", "categories",
            "statistic", "reply ratio", "reply time", "response time",
            "language", "translate",
            "cleanup", "storage", "disk", "space",
            "unanswered", "unreplied",
            "busiest", "quietest",
            "compare", "versus", "vs",
            "scan for", "check for", "detect",
            "date range",
        ]
        return structuredPatterns.contains { lower.contains($0) }
    }

    nonisolated private static func enhancedNLPPipeline(
        query: String,
        emails: [MBOXParser.RawEmail],
        priorContext: String,
        predictions: [UUID: Double]
    ) async -> (answer: String, retrievedIDs: [UUID]) {
        // Check cache first
        if let cached = checkNLPCache(query: query, emailCount: emails.count) {
            return (cached.answer, cached.emailIDs)
        }

        var answer: String
        var retrievedIDs: [UUID]

        if isStructuredQuery(query) {
            // Structured queries: NLP handler first (deterministic, exact)
            answer = processNLPQuery(query, emails: emails, priorContext: priorContext, predictions: predictions)
            let quickRetrieve = await retrieveRelevantEmails(query: query, emails: emails, priorContext: priorContext, predictions: predictions)
            retrievedIDs = Array(quickRetrieve.prefix(5).map(\.id))

            // Condense overly long numbered lists into grouped summaries
            if isLongNumberedList(answer) {
                answer = condenseLongList(answer, query: query, emails: emails)
            }

            // Enrich with chunk evidence
            let (enriched, evidenceIDs) = enrichWithChunkEvidence(answer: answer, query: query, emails: quickRetrieve)
            answer = enriched
            for eid in evidenceIDs where !retrievedIDs.contains(eid) {
                retrievedIDs.append(eid)
            }
        } else {
            // Open-ended queries: retrieval FIRST (bounded FTS5 over the whole
            // archive — was the in-RAM EmailSearchIndex), then synthesize.
            let ftsResults = (try? await ArchiveRetrievalService.shared.retrieve(query, limit: 20)) ?? []
            var retrieved = ftsResults.map(\.email)

            // Also try the NLP keyword retrieval path over the working set
            let nlpRetrieve = await retrieveRelevantEmails(query: query, emails: emails, priorContext: priorContext, predictions: predictions)

            // Merge: hybrid results first, then NLP results (deduplicated)
            var seenIDs = Set(retrieved.map(\.id))
            for email in nlpRetrieve where !seenIDs.contains(email.id) {
                retrieved.append(email)
                seenIDs.insert(email.id)
            }

            retrievedIDs = Array(retrieved.prefix(8).map(\.id))

            if !retrieved.isEmpty {
                // Run NLP handler to see if a structured handler matches better
                let nlpResult = processNLPQuery(query, emails: emails, priorContext: priorContext, predictions: predictions)

                if nlpSaidNoResults(nlpResult) || nlpResult.contains("I'm not sure I understood") {
                    let synthesized = synthesizeFromRetrievedEmails(query: query, emails: Array(retrieved.prefix(20)))
                    answer = synthesized.isEmpty ? nlpResult : synthesized
                } else if isLongNumberedList(nlpResult) {
                    // NLP returned a raw list — condense it
                    answer = condenseLongList(nlpResult, query: query, emails: emails)
                } else {
                    // NLP had a good structured answer — use it
                    answer = nlpResult
                }

                // Enrich with chunk evidence from the semantically-retrieved emails
                let (enriched, evidenceIDs) = enrichWithChunkEvidence(answer: answer, query: query, emails: Array(retrieved.prefix(10)))
                answer = enriched
                for eid in evidenceIDs where !retrievedIDs.contains(eid) {
                    retrievedIDs.append(eid)
                }
            } else {
                // Nothing found anywhere — fall back to NLP handler
                answer = processNLPQuery(query, emails: emails, priorContext: priorContext, predictions: predictions)
                retrievedIDs = []
            }
        }

        // Enrich with pre-computed sender/topic/timeline context
        answer = enrichWithPrecomputedContext(answer: answer, query: query)

        // Cache the result
        cacheNLPAnswer(query: query, answer: answer, emailIDs: retrievedIDs, emailCount: emails.count)

        return (answer, retrievedIDs)
    }

    // MARK: - Hybrid NLP + Apple AI

    nonisolated private static func retrieveRelevantEmails(query: String, emails: [MBOXParser.RawEmail], priorContext: String, predictions: [UUID: Double]) async -> [MBOXParser.RawEmail] {
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

        // Bounded FTS5 retrieval over the whole archive (was in-RAM hybridSearch)
        if !searchTerms.isEmpty {
            let indexResults = (try? await ArchiveRetrievalService.shared.retrieve(lower, limit: 20)) ?? []
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

    // MARK: - Agentic RAG

    private struct AgenticRAGResult {
        let retrievedEmails: [MBOXParser.RawEmail]
        let keyChunks: [(subject: String, from: String, chunk: String)]
        let threadTimeline: String
        let enrichedAnalysis: String
        let steps: [String]
    }

    nonisolated private static func rerankByQueryRelevance(
        _ emails: [MBOXParser.RawEmail],
        query: String,
        terms: [String]
    ) -> [MBOXParser.RawEmail] {
        let scored: [(MBOXParser.RawEmail, Double)] = emails.map { email in
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let from = (email.headers["From"] ?? "").lowercased()
            let body = (email.plainBody.isEmpty ? email.htmlBody : email.plainBody).lowercased()
            let combined = "\(subject) \(from) \(body)"

            var score = 0.0
            for term in terms {
                if subject.contains(term) { score += 3.0 }
                if from.contains(term) { score += 2.0 }
                let bodyCount = combined.components(separatedBy: term).count - 1
                score += min(Double(bodyCount), 5.0) * 0.5
            }

            if let embedding = NLEmbedding.wordEmbedding(for: .english) {
                var simSum = 0.0
                var simCount = 0
                let subjectWords = subject.split(separator: " ").map(String.init)
                for term in terms {
                    guard embedding.vector(for: term) != nil else { continue }
                    for word in subjectWords {
                        guard embedding.vector(for: word) != nil else { continue }
                        let dist = embedding.distance(between: term, and: word)
                        simSum += max(0, 1.0 - dist)
                        simCount += 1
                    }
                }
                if simCount > 0 { score += (simSum / Double(simCount)) * 2.0 }
            }

            return (email, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    nonisolated private static func agenticRetrieve(
        query: String,
        emails: [MBOXParser.RawEmail],
        priorContext: String,
        predictions: [UUID: Double],
        priorRetrievedIDs: Set<UUID> = []
    ) async -> AgenticRAGResult {
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
            let indexResults = (try? await ArchiveRetrievalService.shared.retrieve(lower, limit: 25)) ?? []
            if indexResults.count >= 3 {
                var results = indexResults
                if !predictions.isEmpty {
                    results = boostWithPredictions(results, predictions: predictions)
                }
                initialEmails = results.map(\.email)
                steps.append("FTS5 bm25 retrieval: \(initialEmails.count) emails for [\(searchTerms.joined(separator: ", "))]")
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

        // === Step 2: Thread expansion (bounded FTS/SQL lookup, capped) ===
        let beforeExpansion = initialEmails.count
        let expanded = await ArchiveRetrievalService.shared.expandThread(initialEmails, cap: 50)
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

        // === Step 2.5: Rerank by query relevance ===
        if finalEmails.count > 3 && !searchTerms.isEmpty {
            finalEmails = rerankByQueryRelevance(finalEmails, query: lower, terms: searchTerms)
            steps.append("Reranked \(finalEmails.count) emails by query relevance")
        }

        // === Step 3: Chunk-level extraction (pure, over the bounded set) ===
        let chunkResults = ArchiveEvidenceService.chunkExcerpts(terms: searchTerms, in: finalEmails, maxChunksPerEmail: 2, limit: 10)
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
                let sorted = thread.members.sorted {
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
                let trend = EmailNLPEngine.threadSentimentTrend(thread.members)
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
        if sentiment.average > 0.4 { toneDesc = "very positive" }
        else if sentiment.average > 0.1 { toneDesc = "friendly and positive" }
        else if sentiment.average > -0.1 { toneDesc = "professional and neutral" }
        else if sentiment.average > -0.4 { toneDesc = "somewhat formal or critical" }
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
            if unique.count == 1, let first = unique.first {
                result += "**Topic discussed:** \(first)\n\n"
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

    nonisolated private static func formatInterval(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)
        let days = Int(seconds / 86400)
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s")" }
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(max(1, minutes)) minute\(minutes == 1 ? "" : "s")"
    }

    // MARK: - Conversation Persistence

    private struct SavedTurn: Codable {
        let query: String
        let answer: String
        var timestamp: Date?
        var relatedEmailIDs: [UUID]?
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
        let turns = conversationHistory.suffix(20).map { SavedTurn(query: $0.query, answer: $0.answer, timestamp: $0.timestamp, relatedEmailIDs: $0.relatedEmailIDs) }
        if let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: Self.conversationURL, options: [.atomic, .completeFileProtection])
        }
    }

    private func loadConversation() {
        guard conversationHistory.isEmpty,
              let data = try? Data(contentsOf: Self.conversationURL),
              let turns = try? JSONDecoder().decode([SavedTurn].self, from: data) else { return }
        conversationHistory = turns.map { (query: $0.query, answer: $0.answer, timestamp: $0.timestamp ?? Date(), relatedEmailIDs: $0.relatedEmailIDs ?? []) }
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
        markdown += "**Emails analyzed:** \(emailCount(for: emailScope))\n"
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
            do { try markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                reportExportError = error.localizedDescription
            }
        }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-report.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
            showShareSheet = true
        } catch {
            // Surfaced instead of silently sharing a missing file.
            print("Report export failed: \(error.localizedDescription)")
        }
        #endif
    }
}

#Preview {
    AIAssistantView(archiveScope: .all, onSelectEmail: nil, onFilterByIDs: nil)
}
