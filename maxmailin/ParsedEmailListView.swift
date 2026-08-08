import SwiftUI
import UniformTypeIdentifiers
import TipKit

struct ParsedEmailListView: View {
    @ObservedObject var model: ParsedEmailListViewModel
    @Binding var selectedEmailIDs: Set<UUID>
    @EnvironmentObject var storeManager: StoreManager
    @ObservedObject private var forensicManager = ForensicManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @ObservedObject private var predictiveEngine = PredictiveCodingEngine.shared
    @ObservedObject private var custodianManager = CustodianManager.shared
    @AppStorage("enableAIFeatures") private var enableAIFeatures = true
    @FocusState private var isSearchFieldFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
 
    private enum ActiveSheet: Identifiable {
        case stats
        case rawSource(String)

        var id: String {
            switch self {
            case .stats: return "stats"
            case .rawSource: return "rawSource"
            }
        }
    }

   


    @State private var activeSheet: ActiveSheet?
    @State private var hoveringEmailID: UUID? = nil
    @State private var showAnalyticsSheet = false
    @State private var quickFilterSent = false
    @State private var quickFilterReceived = false
    @State private var quickFilterAttachments = false
    @State private var quickFilterFlagged = false
    @State private var quickFilterUnreviewed = false
    @State private var quickFilterLargeEmails = false
    @State private var quickFilterPrivileged = false
    @State private var quickFilterHighPriority = false
    @State private var quickFilterHasLinks = false
    @State private var showSaveSearchAlert = false
    @State private var saveSearchName = ""
    @State private var showCleanupMode = false
    // Part G9: cleanup stats are store aggregates (SUM / GROUP BY), loaded by
    // cleanupModeView's .task — never derived from the resident preview.
    @State private var cleanupTotalSizeBytes = 0
    @State private var cleanupSenderRollups: [SQLiteEmailStore.SenderRollup] = []
    @State private var quickFilterAIImportant = false
    @State private var quickFilterAISuspicious = false
    @State private var quickFilterAINegative = false
    @State private var quickFilterAINewsletter = false
    @State private var quickFilterTagPersonal = false
    @State private var quickFilterTagTransactional = false
    @State private var quickFilterTagPromotional = false
    @State private var quickFilterTagAutomated = false
    @State private var quickFilterTagRelevant = false
    @State private var quickFilterTagPositive = false
    @State private var quickFilterTagPhishing = false
    @State private var quickFilterTagNeutral = false
    @State private var quickFilterTagIrrelevant = false
    @State private var quickFilterTagSuspicious = false
    @State private var quickFilterTagMediumPriority = false
    @State private var activeFilterTags: Set<String> = []
    @State private var manualOverrideTags: [UUID: Set<EmailQuickTag>] = [:]
    @State private var tagPopoverEmailID: UUID? = nil
    @State private var showPresetSaveAlert = false
    @State private var presetName = ""
    @AppStorage("savedFilterPresets") private var savedPresetsData: Data = Data()
    @AppStorage("aiTagsApplied") private var aiTagsApplied = false
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false
    @AppStorage("personaFiltersInitialized") private var personaFiltersInitialized = false
    @State private var showAIPaywall = false
    private static let freeAIFilterLimit = 5
    @AppStorage("freeAIFilterUsageCount") private var aiFilterUsageCount: Int = 0
    @State private var listExportError: String?
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif

    private var quickFilteredEmails: [MBOXParser.RawEmail] {
        model.visibleEmails.filter { email in
            // Sent/Received/Attachments chips compile to SQL (see
            // syncQuickFiltersToQuery) — visibleEmails is already
            // restricted, and the SQL flag knows about header-recovered
            // rows whose attachment METADATA is unrecoverable.
            if quickFilterFlagged {
                let tag = ForensicManager.shared.evidenceTags[email.id] ?? .none
                if tag != .flagged && tag != .suspicious { return false }
            }
            if quickFilterUnreviewed {
                let tag = ForensicManager.shared.evidenceTags[email.id] ?? .none
                if tag != .none { return false }
            }
            if quickFilterLargeEmails {
                let size = email.rawSource.utf8.count
                if size < 100_000 { return false }
            }
            if quickFilterPrivileged {
                let tag = ForensicManager.shared.evidenceTags[email.id] ?? .none
                if tag != .privileged { return false }
            }
            // High Priority / AI Important / Suspicious / Negative /
            // Newsletter compile to SQL over persisted derived records (see
            // syncQuickFiltersToQuery) — no in-window re-check, which would
            // disagree with the persisted scores and drop SQL matches.
            if quickFilterHasLinks {
                let body = email.plainBody.lowercased()
                if !body.contains("http://") && !body.contains("https://") && !body.contains("www.") { return false }
            }

            let active = activeTags(for: email)
            let activeSet = Set(active)
            if quickFilterTagPersonal && !activeSet.contains(.personal) { return false }
            if quickFilterTagTransactional && !activeSet.contains(.transactional) { return false }
            if quickFilterTagPromotional && !activeSet.contains(.promotional) { return false }
            if quickFilterTagAutomated && !activeSet.contains(.automated) { return false }
            if quickFilterTagRelevant && !activeSet.contains(.relevant) { return false }
            if quickFilterTagPositive && !activeSet.contains(.positive) { return false }
            if quickFilterTagPhishing && !activeSet.contains(.phishing) { return false }
            if quickFilterTagNeutral && !activeSet.contains(.neutral) { return false }
            if quickFilterTagIrrelevant && !activeSet.contains(.irrelevant) { return false }
            if quickFilterTagSuspicious && !activeSet.contains(.suspicious) { return false }
            if quickFilterTagMediumPriority && !activeSet.contains(.mediumPriority) { return false }
            return true
        }
    }

    private var quickFilteredThreads: [EmailThread] {
        let hasQuickFilter = quickFilterSent || quickFilterReceived || quickFilterAttachments || quickFilterFlagged || quickFilterUnreviewed || quickFilterLargeEmails || quickFilterPrivileged || quickFilterHighPriority || quickFilterHasLinks || quickFilterAIImportant || quickFilterAISuspicious || quickFilterAINegative || quickFilterAINewsletter || quickFilterTagPersonal || quickFilterTagTransactional || quickFilterTagPromotional || quickFilterTagAutomated || quickFilterTagRelevant || quickFilterTagPositive || quickFilterTagPhishing || quickFilterTagNeutral || quickFilterTagIrrelevant || quickFilterTagSuspicious || quickFilterTagMediumPriority
        guard hasQuickFilter else { return model.emailThreads }
        let allowedIDs = Set(quickFilteredEmails.map(\.id))
        return model.emailThreads.compactMap { thread in
            let filteredReplies = thread.replies.filter { allowedIDs.contains($0.id) }
            let rootIncluded = allowedIDs.contains(thread.root.id)
            if !rootIncluded && filteredReplies.isEmpty { return nil }
            if rootIncluded {
                return EmailThread(id: thread.id, subject: thread.subject, root: thread.root, replies: filteredReplies)
            }
            guard let firstReply = filteredReplies.first else { return nil }
            return EmailThread(id: thread.id, subject: thread.subject, root: firstReply, replies: Array(filteredReplies.dropFirst()))
        }
    }

    #if os(macOS)
    /// One inspector serves stats / raw source / analytics — whichever was
    /// requested last; closing it clears every request.
    private var detailInspectorPresented: Binding<Bool> {
        Binding(
            get: { activeSheet != nil || showAnalyticsSheet },
            set: { shown in
                if !shown {
                    activeSheet = nil
                    showAnalyticsSheet = false
                }
            }
        )
    }

    @ViewBuilder
    private var detailInspectorContent: some View {
        if let sheet = activeSheet {
            switch sheet {
            case .stats:
                ReplyStatsView(senderEmail: model.viewModel.senderEmail)
            case .rawSource(let rfc822):
                RawSourceView(rawText: rfc822)
            }
        } else if showAnalyticsSheet {
            EmailAnalyticsView(query: model.currentArchiveQuery)
        }
    }
    #endif

    // MARK: - UI
    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    #if os(iOS)
    @State private var showIOSFilters = false

    private var iOSBody: some View {
        VStack(spacing: 0) {
            iOSSearchBar
            if showIOSFilters {
                quickFilterBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            contentView
        }
        .background(Color(.systemGroupedBackground))
        .animation(.easeInOut(duration: 0.25), value: showIOSFilters)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .stats:
                ReplyStatsView(senderEmail: model.viewModel.senderEmail)
            case .rawSource(let rfc822):
                RawSourceView(rawText: rfc822)
            }
        }
        .sheet(isPresented: $showAnalyticsSheet) {
            EmailAnalyticsView(query: model.currentArchiveQuery)
        }
        #if !DEBUG
        .sheet(isPresented: $showAIPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        #endif
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert("Export Error", isPresented: Binding(get: { listExportError != nil }, set: { if !$0 { listExportError = nil } })) {
            Button("OK") { listExportError = nil }
        } message: {
            Text(listExportError ?? "An unknown error occurred.")
        }
    }

    private var iOSSearchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField(model.isNaturalLanguageMode ? "Ask naturally..." : "Search emails...", text: $model.searchText)
                    .font(.subheadline)
                    .focused($isSearchFieldFocused)
                    .onChange(of: model.searchText) { _, newValue in
                        model.searchTextDidChange()
                        if !newValue.isEmpty {
                            Task { await SearchSyntaxTip.searchUsed.donate() }
                        }
                    }
                    .onChange(of: model.isSearchFocused) { _, newValue in
                        if newValue {
                            isSearchFieldFocused = true
                            model.isSearchFocused = false
                        }
                    }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                        model.hasAttachmentFilter = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill))
            .cornerRadius(10)

            Button {
                withAnimation { showIOSFilters.toggle() }
            } label: {
                Image(systemName: showIOSFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .foregroundColor(hasAnyQuickFilterActive ? .accentColor : .secondary)
            }

            Menu {
                Button { model.isNaturalLanguageMode.toggle() } label: {
                    Label(model.isNaturalLanguageMode ? "Keyword Search" : "Natural Language", systemImage: model.isNaturalLanguageMode ? "text.magnifyingglass" : "brain")
                }
                Button { model.groupByThread.toggle() } label: {
                    Label(model.groupByThread ? "Ungroup Threads" : "Group by Thread", systemImage: "bubble.left.and.bubble.right")
                }
                Divider()
                ForEach(ParsedEmailListViewModel.SortOption.allCases, id: \.self) { option in
                    Button {
                        model.sortBy = option
                        model.applyFilters()
                    } label: {
                        if model.sortBy == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
                Divider()
                if totalAttachments > 0 {
                    Button { downloadAllAttachments() } label: {
                        Label("Export Attachments (\(totalAttachments))", systemImage: "arrow.down.circle")
                    }
                }
                if !model.visibleEmails.isEmpty {
                    Menu {
                        unifiedExportSections
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                }
                Button { showAnalyticsSheet = true } label: {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }

        // Part P: user-visible search caveats — never silently truncated.
        if let notice = model.searchNotice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityLabel("Search notice: \(notice)")
        }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    #endif

    private var macOSBody: some View {
        VStack(spacing: Spacing.xxSmall) {
            headerView
            quickFilterBar
            Divider()
            contentView

            if totalAttachments > 0 || !model.visibleEmails.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xxSmall) {
                        if totalAttachments > 0 {
                            Button {
                                downloadAllAttachments()
                            } label: {
                                Label("Export (\(totalAttachments))", systemImage: "arrow.down.circle.fill")
                                    .font(Typography.caption1)
                            }
                            .buttonStyle(CompactPrimaryButtonStyle())
                            .controlSize(.small)
                        }

                        if !model.visibleEmails.isEmpty {
                            Menu {
                                unifiedExportSections
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                                    .font(Typography.caption1)
                            }
                            .controlSize(.small)
                            .fixedSize()
                            .help("Export the filtered email list — documents, per-email files, contacts, events")
                            .accessibilityLabel("Export filtered emails")
                        }

                        Button {
                            showAnalyticsSheet = true
                        } label: {
                            Label(personaManager.config.showAnalyticsProminent ? "Discover Patterns" : "Analytics",
                                  systemImage: personaManager.config.showAnalyticsProminent ? "sparkle.magnifyingglass" : "chart.bar.xaxis")
                                .font(personaManager.config.showAnalyticsProminent ? .footnote : .caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, personaManager.config.showAnalyticsProminent ? 14 : 10)
                                .padding(.vertical, personaManager.config.showAnalyticsProminent ? 7 : 5)
                                .background(
                                    LinearGradient(
                                        colors: personaManager.config.showAnalyticsProminent ? [.purple, .blue] : [.orange, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Email analytics")

                        if enableAIFeatures {
                            AIWindowButton(model: model)
                                .environmentObject(storeManager)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, Spacing.xxxSmall)
                .padding(.horizontal, Spacing.xxSmall)
            }
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, Spacing.xxSmall)
        .background(AppColors.backgroundPrimary)
        // macOS: stats / raw source / analytics live in a native resizable
        // inspector panel (the modern macOS detail affordance) instead of
        // modal sheets; iOS keeps sheets, its native pattern.
        #if os(macOS)
        .inspector(isPresented: detailInspectorPresented) {
            detailInspectorContent
                .inspectorColumnWidth(min: 380, ideal: 480, max: 720)
        }
        #else
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .stats:
                ReplyStatsView(senderEmail: model.viewModel.senderEmail)
                    .presentationDetents([.large])
            case .rawSource(let rfc822):
                RawSourceView(rawText: rfc822)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showAnalyticsSheet) {
            EmailAnalyticsView(query: model.currentArchiveQuery)
                .presentationDetents([.large])
        }
        #endif
        #if !DEBUG
        .sheet(isPresented: $showAIPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        #endif
        .alert("Save Search", isPresented: $showSaveSearchAlert) {
            TextField("Search name", text: $saveSearchName)
            Button("Save") {
                model.saveCurrentSearch(name: saveSearchName.isEmpty ? model.searchText : saveSearchName)
                saveSearchName = ""
            }
            Button("Cancel", role: .cancel) { saveSearchName = "" }
        } message: {
            Text("Give this search a name for quick access later.")
        }
        .alert("Export Error", isPresented: Binding(get: { listExportError != nil }, set: { if !$0 { listExportError = nil } })) {
            Button("OK") { listExportError = nil }
        } message: {
            Text(listExportError ?? "An unknown error occurred.")
        }
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .stats
                } label: {
                    Label("Reply Stats", systemImage: "chart.bar")
                }
            }
        }
    }


    // MARK: - Header
    private var headerView: some View {
        VStack(spacing: Spacing.xxSmall) {
            HStack(spacing: Spacing.xSmall) {
                Text(personaListTitle)
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)

                if !model.visibleEmails.isEmpty {
                    // Part G3: unfiltered → store-backed archive total; filtered
                    // → the visible (preview-backed) list count.
                    Text("\(model.displayedEmailCount)")
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppColors.primary)
                        .clipShape(Capsule())
                }

                Spacer()

                Toggle(isOn: $model.groupByThread) {
                    Label {
                        #if os(macOS)
                        Text("Threads")
                        #else
                        EmptyView()
                        #endif
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .font(Typography.caption1)
                }
                .toggleStyle(.button)
                #if os(macOS)
                .help("Group emails into conversation threads")
                #endif
                .accessibilityLabel("Group by thread")
                .accessibilityHint("Toggle conversation threading")
                .accessibilityAddTraits(model.groupByThread ? .isSelected : [])

                Menu {
                    ForEach(ParsedEmailListViewModel.SortOption.allCases, id: \.self) { option in
                        Button {
                            model.sortBy = option
                            model.applyFilters()
                        } label: {
                            if model.sortBy == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.footnote)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                #if os(macOS)
                .help("Change the order emails are displayed")
                #endif
                .accessibilityLabel("Sort order: \(model.sortBy.label)")
            }

            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundColor(AppColors.secondary)
                TextField(model.isNaturalLanguageMode ? {
                    #if os(iOS)
                    return "Ask naturally..."
                    #else
                    return "Ask naturally, e.g. \"John's emails from last week with attachments\""
                    #endif
                }() : {
                    #if os(iOS)
                    return "Search emails..."
                    #else
                    return "Search — try from:name, AND/OR/NOT, \"exact phrase\", or /regex/"
                    #endif
                }(), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel(model.isNaturalLanguageMode ? "Natural language search" : "Search emails")
                    .accessibilityHint(model.isNaturalLanguageMode ? "Type a natural language query to filter emails" : "Supports operators: from:, to:, subject:, has:attachment, before:, after:")
                    .onChange(of: model.searchText) { _, newValue in
                        model.searchTextDidChange()
                        if !newValue.isEmpty {
                            Task { await SearchSyntaxTip.searchUsed.donate() }
                        }
                    }
                    .onChange(of: model.isSearchFocused) { _, newValue in
                        if newValue {
                            isSearchFieldFocused = true
                            model.isSearchFocused = false
                        }
                    }

                Button {
                    model.isNaturalLanguageMode.toggle()
                    if !model.searchText.isEmpty {
                        model.searchTextDidChange()
                    }
                } label: {
                    Text("NL")
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(model.isNaturalLanguageMode ? .white : AppColors.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(model.isNaturalLanguageMode ? AppColors.primary : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(model.isNaturalLanguageMode ? Color.clear : AppColors.secondary.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(model.isNaturalLanguageMode ? "Switch to keyword search" : "Switch to natural language search")
                #endif
                .accessibilityLabel(model.isNaturalLanguageMode ? "Natural language mode active" : "Enable natural language mode")

                if !model.searchText.isEmpty {
                    Button {
                        showSaveSearchAlert = true
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .foregroundColor(AppColors.primary)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Save this search")
                    #endif
                    .accessibilityLabel("Save current search")

                    Button {
                        model.searchText = ""
                        model.hasAttachmentFilter = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }

                if !model.savedSearches.isEmpty {
                    Menu {
                        ForEach(model.savedSearches) { search in
                            Button {
                                model.searchText = search.query
                            } label: {
                                Label(search.name, systemImage: "bookmark")
                            }
                        }
                        Divider()
                        Menu("Remove") {
                            ForEach(model.savedSearches) { search in
                                Button(role: .destructive) {
                                    model.deleteSavedSearch(search)
                                } label: {
                                    Text(search.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "bookmark")
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Saved searches")
                    #endif
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xxSmall)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: CornerRadius.medium))

            // Part P: user-visible search caveats (regex cap truncation /
            // attachment filename-only matching) — never silently truncated.
            if let notice = model.searchNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, Spacing.small)
                    .accessibilityLabel("Search notice: \(notice)")
            }
        }
    }

    // MARK: - AI Filter Helpers

    private var hasAnyAIFilter: Bool {
        let cfg = personaManager.config.showQuickFilters
        return cfg.contains(.aiImportant) || cfg.contains(.aiSuspicious) || cfg.contains(.aiNegative) || cfg.contains(.aiNewsletter)
    }

    private var hasAnyQuickFilterActive: Bool {
        quickFilterSent || quickFilterReceived || quickFilterAttachments || quickFilterFlagged || quickFilterUnreviewed || quickFilterLargeEmails || quickFilterPrivileged || quickFilterHighPriority || quickFilterHasLinks || quickFilterAIImportant || quickFilterAISuspicious || quickFilterAINegative || quickFilterAINewsletter || quickFilterTagPersonal || quickFilterTagTransactional || quickFilterTagPromotional || quickFilterTagAutomated || quickFilterTagRelevant || quickFilterTagPositive || quickFilterTagPhishing || quickFilterTagNeutral || quickFilterTagIrrelevant || quickFilterTagSuspicious || quickFilterTagMediumPriority
    }

    /// Push the SQL-capable chips into the compiled archive query (the
    /// other chips stay window refinements — they filter derived/AI state).
    private func syncQuickFiltersToQuery() {
        model.quickTypeFilter = quickFilterSent && !quickFilterReceived ? "sent"
            : (quickFilterReceived && !quickFilterSent ? "received" : nil)
        model.hasAttachmentFilter = quickFilterAttachments
        // AI chips: archive-wide via persisted derived records. High
        // Priority (>=4) wins over AI Important (>=3) when both are on.
        model.quickMinPriority = quickFilterHighPriority ? 4 : (quickFilterAIImportant ? 3 : nil)
        model.quickPhishingOnly = quickFilterAISuspicious
        model.quickNegativeOnly = quickFilterAINegative
        model.quickNewsletterOnly = quickFilterAINewsletter
        model.applyFilters()
    }

    private func clearAllQuickFilters() {
        quickFilterSent = false
        quickFilterReceived = false
        quickFilterAttachments = false
        quickFilterFlagged = false
        quickFilterUnreviewed = false
        quickFilterLargeEmails = false
        quickFilterPrivileged = false
        quickFilterHighPriority = false
        quickFilterHasLinks = false
        quickFilterAIImportant = false
        quickFilterAISuspicious = false
        quickFilterAINegative = false
        quickFilterAINewsletter = false
        quickFilterTagPersonal = false
        quickFilterTagTransactional = false
        quickFilterTagPromotional = false
        quickFilterTagAutomated = false
        quickFilterTagRelevant = false
        quickFilterTagPositive = false
        quickFilterTagPhishing = false
        quickFilterTagNeutral = false
        quickFilterTagIrrelevant = false
        quickFilterTagSuspicious = false
        quickFilterTagMediumPriority = false
        syncQuickFiltersToQuery()
        activeFilterTags.removeAll()
    }

    private func aiFilterBinding(for binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if newValue && !storeManager.isPremium {
                    if aiFilterUsageCount >= Self.freeAIFilterLimit {
                        showAIPaywall = true
                        return
                    }
                    aiFilterUsageCount += 1
                }
                binding.wrappedValue = newValue
            }
        )
    }

    // MARK: - Quick Filter Bar
    private var quickFilterBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xSmall) {
                    ForEach(activeFilterChips, id: \.key) { chip in
                        let isAIChip = Self.aiFilterKeys.contains(chip.key)
                        if !isAIChip || aiTagsApplied {
                            DismissableFilterChip(
                                label: chip.label,
                                icon: chip.icon,
                                color: isAIChip ? chip.color.opacity(aiTagsApplied ? 1 : 0.4) : chip.color,
                                isActive: filterBinding(for: chip.key),
                                onRemove: { removeFilterChip(chip.key) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.xSmall)
            }

            HStack(spacing: 4) {
                Button {
                    aiTagsApplied.toggle()
                    Task { await AIToggleTip.filtersUsed.donate() }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: aiTagsApplied ? "brain.fill" : "brain")
                            .font(.system(size: 10))
                        Text(aiTagsApplied ? "AI On" : "AI")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(aiTagsApplied ? .white : AppColors.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(aiTagsApplied ? AppColors.primary : AppColors.primary.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .popoverTip(AIToggleTip(), arrowEdge: .bottom)
                #if os(macOS)
                .help(aiTagsApplied ? "AI tags active — click to show basic tags only" : "Apply AI classification, sentiment & priority tags")
                #endif

                Button {
                    showAdvancedFeatures.toggle()
                    Task { await ProToggleTip.filtersUsed.donate() }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: showAdvancedFeatures ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 10))
                        Text(showAdvancedFeatures ? "Pro" : "Pro")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(showAdvancedFeatures ? .white : AppColors.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(showAdvancedFeatures ? AppColors.secondary : AppColors.secondary.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .popoverTip(ProToggleTip(), arrowEdge: .bottom)
                #if os(macOS)
                .help(showAdvancedFeatures ? "Advanced features visible — click to simplify" : "Show forensic, legal & advanced features")
                #endif

                addFilterMenu

                presetMenu

                if hasAnyQuickFilterActive {
                    Button {
                        clearAllQuickFilters()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Clear all filters")
                    #endif
                }
            }
            .padding(.trailing, Spacing.xSmall)
        }
        .onAppear { initializePersonaFilters() }
        .onChange(of: personaFiltersInitialized) { _, newValue in
            if !newValue { initializePersonaFilters() }
        }
        .alert("Save Preset", isPresented: $showPresetSaveAlert) {
            TextField("Preset name", text: $presetName)
            Button("Save") { saveCurrentPreset() }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Enter a name for this filter preset.")
        }
    }

    private static let aiFilterKeys: Set<String> = [
        "personal", "transactional", "newsletter", "promotional", "automated",
        "positive", "negative", "neutral",
        "highPriority", "mediumPriority", "important",
        "phishing", "aiSuspicious"
    ]

    private static let advancedFilterKeys: Set<String> = [
        "privileged", "relevant", "irrelevant", "flagged", "suspicious",
        "unreviewed", "cleanup"
    ]

    private func initializePersonaFilters() {
        guard !personaFiltersInitialized else { return }
        personaFiltersInitialized = true

        let persona = personaManager.selectedPersona
        switch persona {
        case .forensic:
            activeFilterTags = ["sent", "received", "flagged", "suspicious", "relevant", "unreviewed"]
            showAdvancedFeatures = true
            aiTagsApplied = true
        case .legal:
            activeFilterTags = ["privileged", "relevant", "irrelevant", "attachments"]
            showAdvancedFeatures = true
            aiTagsApplied = false
        case .itAdmin:
            activeFilterTags = ["sent", "received", "attachments", "phishing", "highPriority"]
            showAdvancedFeatures = false
            aiTagsApplied = true
        case .journalist:
            activeFilterTags = ["sent", "received", "personal", "negative", "positive"]
            showAdvancedFeatures = false
            aiTagsApplied = true
        case .personal:
            activeFilterTags = ["sent", "received", "attachments"]
            showAdvancedFeatures = false
            aiTagsApplied = false
        case .general:
            activeFilterTags = ["sent", "received", "attachments", "highPriority"]
            showAdvancedFeatures = false
            aiTagsApplied = false
        }
    }

    private struct FilterChipInfo: Identifiable {
        let key: String
        let label: String
        let icon: String
        let color: Color
        let section: String
        var id: String { key }
    }

    private static let allFilterChips: [FilterChipInfo] = [
        FilterChipInfo(key: "sent", label: "Sent", icon: "arrow.up.right", color: .blue, section: "Type"),
        FilterChipInfo(key: "received", label: "Received", icon: "arrow.down.left", color: .teal, section: "Type"),
        FilterChipInfo(key: "attachments", label: "Attachments", icon: "paperclip", color: .brown, section: "Type"),
        FilterChipInfo(key: "hasLinks", label: "Has Links", icon: "link", color: .indigo, section: "Type"),
        FilterChipInfo(key: "largeEmails", label: "Large Emails", icon: "arrow.up.circle", color: .orange, section: "Type"),

        FilterChipInfo(key: "personal", label: "Personal", icon: "person.fill", color: .cyan, section: "Category"),
        FilterChipInfo(key: "transactional", label: "Transactional", icon: "creditcard", color: .indigo, section: "Category"),
        FilterChipInfo(key: "newsletter", label: "Newsletters", icon: "newspaper.fill", color: .mint, section: "Category"),
        FilterChipInfo(key: "promotional", label: "Promotional", icon: "megaphone", color: .pink, section: "Category"),
        FilterChipInfo(key: "automated", label: "Automated", icon: "gearshape", color: .gray, section: "Category"),

        FilterChipInfo(key: "relevant", label: "Relevant", icon: "checkmark.seal.fill", color: .green, section: "Evidence"),
        FilterChipInfo(key: "privileged", label: "Privileged", icon: "lock.shield.fill", color: .orange, section: "Evidence"),
        FilterChipInfo(key: "irrelevant", label: "Irrelevant", icon: "xmark.circle", color: .gray, section: "Evidence"),
        FilterChipInfo(key: "flagged", label: "Flagged", icon: "flag.fill", color: .red, section: "Evidence"),
        FilterChipInfo(key: "suspicious", label: "Suspicious", icon: "exclamationmark.triangle.fill", color: .purple, section: "Evidence"),

        FilterChipInfo(key: "positive", label: "Positive", icon: "face.smiling", color: .green, section: "Sentiment"),
        FilterChipInfo(key: "negative", label: "Negative", icon: "face.dashed", color: .red, section: "Sentiment"),
        FilterChipInfo(key: "neutral", label: "Neutral", icon: "minus.circle", color: .gray, section: "Sentiment"),

        FilterChipInfo(key: "highPriority", label: "High Priority", icon: "exclamationmark.triangle.fill", color: .red, section: "Priority"),
        FilterChipInfo(key: "mediumPriority", label: "Medium Priority", icon: "exclamationmark.circle", color: .orange, section: "Priority"),
        FilterChipInfo(key: "important", label: "Important", icon: "bolt.fill", color: .purple, section: "Priority"),

        FilterChipInfo(key: "phishing", label: "Phishing", icon: "shield.slash", color: .red, section: "Security"),
        FilterChipInfo(key: "aiSuspicious", label: "AI Suspicious", icon: "exclamationmark.shield.fill", color: .purple, section: "Security"),

        FilterChipInfo(key: "unreviewed", label: "Unreviewed", icon: "eye.slash", color: .secondary, section: "Review"),
        FilterChipInfo(key: "cleanup", label: "Cleanup", icon: "trash.circle", color: .secondary, section: "Review"),
    ]

    private var activeFilterChips: [FilterChipInfo] {
        return Self.allFilterChips.filter { activeFilterTags.contains($0.key) }
    }

    private func filterBinding(for key: String) -> Binding<Bool> {
        switch key {
        case "sent": return Binding(
            get: { quickFilterSent },
            set: { quickFilterSent = $0; if $0 { quickFilterReceived = false }; syncQuickFiltersToQuery() })
        case "received": return Binding(
            get: { quickFilterReceived },
            set: { quickFilterReceived = $0; if $0 { quickFilterSent = false }; syncQuickFiltersToQuery() })
        case "attachments": return Binding(
            get: { quickFilterAttachments },
            set: { quickFilterAttachments = $0; syncQuickFiltersToQuery() })
        case "flagged": return $quickFilterFlagged
        case "unreviewed": return $quickFilterUnreviewed
        case "largeEmails": return $quickFilterLargeEmails
        case "privileged": return $quickFilterPrivileged
        case "highPriority": return Binding(
            get: { quickFilterHighPriority },
            set: { quickFilterHighPriority = $0; syncQuickFiltersToQuery() })
        case "hasLinks": return $quickFilterHasLinks
        case "cleanup": return $showCleanupMode
        case "important": return Binding(
            get: { quickFilterAIImportant },
            set: { quickFilterAIImportant = $0; syncQuickFiltersToQuery() })
        case "aiSuspicious": return Binding(
            get: { quickFilterAISuspicious },
            set: { quickFilterAISuspicious = $0; syncQuickFiltersToQuery() })
        case "negative": return Binding(
            get: { quickFilterAINegative },
            set: { quickFilterAINegative = $0; syncQuickFiltersToQuery() })
        case "newsletter": return Binding(
            get: { quickFilterAINewsletter },
            set: { quickFilterAINewsletter = $0; syncQuickFiltersToQuery() })
        case "personal": return $quickFilterTagPersonal
        case "transactional": return $quickFilterTagTransactional
        case "promotional": return $quickFilterTagPromotional
        case "automated": return $quickFilterTagAutomated
        case "relevant": return $quickFilterTagRelevant
        case "positive": return $quickFilterTagPositive
        case "phishing": return $quickFilterTagPhishing
        case "neutral": return $quickFilterTagNeutral
        case "irrelevant": return $quickFilterTagIrrelevant
        case "suspicious": return $quickFilterTagSuspicious
        case "mediumPriority": return $quickFilterTagMediumPriority
        default: return .constant(false)
        }
    }

    private func removeFilterChip(_ key: String) {
        filterBinding(for: key).wrappedValue = false
        activeFilterTags.remove(key)
    }

    /// Persona-recommended chips (PersonaManager.config.showQuickFilters),
    /// mapped to chip keys. Shown as a promoted section — every other filter
    /// stays reachable in its category below, so tailoring never hides
    /// capability.
    private var personaRecommendedChips: [FilterChipInfo] {
        let mapping: [PersonaManager.QuickFilter: String] = [
            .sent: "sent", .received: "received", .attachments: "attachments",
            .cleanup: "cleanup", .flagged: "flagged", .privileged: "privileged",
            .unreviewed: "unreviewed", .highPriority: "highPriority",
            .hasLinks: "hasLinks", .largeEmails: "largeEmails",
            .aiImportant: "important", .aiSuspicious: "aiSuspicious",
            .aiNegative: "negative", .aiNewsletter: "newsletter"
        ]
        let keys = PersonaManager.shared.config.showQuickFilters.compactMap { mapping[$0] }
        return keys.compactMap { key in Self.allFilterChips.first { $0.key == key } }
    }

    private var addFilterMenu: some View {
        Menu {
            let recommended = personaRecommendedChips
            if !recommended.isEmpty {
                Section("For \(PersonaManager.shared.selectedPersona.displayName)") {
                    ForEach(recommended) { chip in
                        filterChipButton(chip)
                    }
                }
            }

            let sections = Dictionary(grouping: Self.allFilterChips, by: \.section)
            let basicSections = ["Type"]
            let aiSections = ["Category", "Sentiment", "Priority", "Security"]
            let advancedSections = ["Evidence", "Review"]

            ForEach(basicSections, id: \.self) { section in
                if let chips = sections[section] {
                    Section(section) {
                        ForEach(chips) { chip in
                            filterChipButton(chip)
                        }
                    }
                }
            }

            if aiTagsApplied {
                ForEach(aiSections, id: \.self) { section in
                    if let chips = sections[section] {
                        Section("\(section) (AI)") {
                            ForEach(chips) { chip in
                                filterChipButton(chip)
                            }
                        }
                    }
                }
            } else {
                Section {
                    Label("Turn on AI to see Category, Sentiment & Priority filters", systemImage: "brain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if showAdvancedFeatures {
                ForEach(advancedSections, id: \.self) { section in
                    if let chips = sections[section] {
                        Section("\(section) (Pro)") {
                            ForEach(chips) { chip in
                                filterChipButton(chip)
                            }
                        }
                    }
                }
            } else {
                Section {
                    Label("Turn on Pro to see Evidence & Review filters", systemImage: "gearshape")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.callout)
                .foregroundColor(AppColors.primary)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help("Add filter")
        #endif
        .accessibilityLabel("Add a filter")
    }

    @ViewBuilder
    private func filterChipButton(_ chip: FilterChipInfo) -> some View {
        let isVisible = activeFilterTags.contains(chip.key)
        Button {
            if !isVisible {
                activeFilterTags.insert(chip.key)
            }
            filterBinding(for: chip.key).wrappedValue = true
        } label: {
            Label {
                HStack {
                    Text(chip.label)
                    if isVisible {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption2)
                    }
                }
            } icon: {
                Image(systemName: chip.icon)
                    .foregroundColor(chip.color)
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("Save") {
                Button {
                    presetName = ""
                    showPresetSaveAlert = true
                } label: {
                    Label("Save Current as Preset", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasAnyQuickFilterActive && activeFilterTags.isEmpty)
            }

            let presets = loadPresetsV2()
            if !presets.isEmpty {
                Section("Load") {
                    ForEach(presets.sorted(by: { $0.key < $1.key }), id: \.key) { name, preset in
                        Button {
                            applyPreset(preset)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(name)
                                    Text(preset.visible.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                            }
                        }
                    }
                }
                Section("Delete") {
                    ForEach(presets.sorted(by: { $0.key < $1.key }), id: \.key) { name, _ in
                        Button(role: .destructive) {
                            deletePreset(name)
                        } label: {
                            Label(name, systemImage: "trash")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.callout)
                .foregroundColor(AppColors.secondary)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help("Filter presets")
        #endif
        .accessibilityLabel("Filter presets")
    }

    private struct FilterPreset: Codable {
        let visible: [String]
        let active: [String]
    }

    private func saveCurrentPreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let visibleKeys = Array(activeFilterTags)
        let activeKeys = visibleKeys.filter { filterBinding(for: $0).wrappedValue }
        guard !visibleKeys.isEmpty else { return }
        var presets = loadPresetsV2()
        presets[trimmed] = FilterPreset(visible: visibleKeys, active: activeKeys)
        if let data = try? JSONEncoder().encode(presets) {
            savedPresetsData = data
        }
        presetName = ""
    }

    private func loadPresetsV2() -> [String: FilterPreset] {
        if let v2 = try? JSONDecoder().decode([String: FilterPreset].self, from: savedPresetsData) {
            return v2
        }
        if let v1 = try? JSONDecoder().decode([String: [String]].self, from: savedPresetsData) {
            return v1.mapValues { FilterPreset(visible: $0, active: $0) }
        }
        return [:]
    }

    private func applyPreset(_ preset: FilterPreset) {
        clearAllQuickFilters()
        for key in preset.visible {
            activeFilterTags.insert(key)
        }
        for key in preset.active {
            filterBinding(for: key).wrappedValue = true
        }
    }

    private func deletePreset(_ name: String) {
        var presets = loadPresetsV2()
        presets.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(presets) {
            savedPresetsData = data
        }
    }

    // MARK: - Main List
    @ViewBuilder
    private var contentView: some View {
        if showCleanupMode {
            cleanupModeView
        } else {
            let emails = quickFilteredEmails
            if emails.isEmpty {
                VStack(spacing: Spacing.medium) {
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No matching emails",
                        message: hasAnyQuickFilterActive
                            ? "Active filter chips are hiding all emails. Clear them to see your \(model.visibleEmails.count) emails."
                            : "No emails match your current filters. Try widening the date range, selecting more senders, or reducing the minimum reply count."
                    )
                    if hasAnyQuickFilterActive {
                        Button {
                            clearAllQuickFilters()
                        } label: {
                            Label("Clear All Quick Filters", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
            } else if model.groupByThread {
                threadedListView
            } else {
                #if os(iOS)
                List {
                    pageWindowHeader
                    ForEach(emails, id: \.id) { email in
                        NavigationLink(value: email.id) {
                            emailRow(for: email)
                        }
                        .padding(.vertical, Spacing.xxxSmall)
                        .onAppear { model.loadMoreIfNeeded(currentID: email.id) }
                    }
                    pageWindowFooter
                }
                .listStyle(.plain)
                #else
                if forensicManager.isEnabled {
                    ForensicReviewView(selectedEmailIDs: $selectedEmailIDs)
                } else {
                    List(selection: $selectedEmailIDs) {
                        pageWindowHeader
                        ForEach(emails, id: \.id) { email in
                            emailRow(for: email)
                                .padding(.vertical, Spacing.xxxSmall)
                                .tag(email.id)
                                .onAppear { model.loadMoreIfNeeded(currentID: email.id) }
                        }
                        pageWindowFooter
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Page window affordances (Part S — bounded window paging)

    /// Deep-scrolled windows drop their earliest pages; this re-fetches them.
    @ViewBuilder
    private var pageWindowHeader: some View {
        if model.hasEarlierPages {
            Button {
                model.loadEarlierPage()
            } label: {
                Label("Load earlier emails", systemImage: "chevron.up")
                    .font(Typography.caption1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load earlier emails")
        }
    }

    @ViewBuilder
    private var pageWindowFooter: some View {
        if model.isLoadingPage {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
        } else if model.hasMorePages {
            Button {
                model.loadNextPage()
            } label: {
                Label("Load more emails", systemImage: "chevron.down")
                    .font(Typography.caption1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load more emails")
        }
    }

    // MARK: - Forensic Table Layout (v3)

    #if os(macOS)
    @ObservedObject private var reviewBatchManager = ReviewBatchManager.shared

    enum ForensicSortKey: String {
        case tag, bates, risk, from, to, subject, date, attachments
    }

    @State private var forensicSortKey: ForensicSortKey = .date
    @State private var forensicSortAscending = false
    @State private var showReviewerStats = false
    @State private var crossPartyFrom = ""
    @State private var crossPartyTo = ""
    @State private var showCrossPartyFilter = false
    @State private var qcSampleIDs: Set<UUID> = []

    private func forensicSortedEmails(_ emails: [MBOXParser.RawEmail]) -> [MBOXParser.RawEmail] {
        let sorted = emails.sorted { a, b in
            let result: Bool
            switch forensicSortKey {
            case .tag:
                let ta = forensicManager.tagForEmail(a.id).rawValue
                let tb = forensicManager.tagForEmail(b.id).rawValue
                result = ta < tb
            case .bates:
                let ba = batesManager.getBatesNumber(for: a.id) ?? ""
                let bb = batesManager.getBatesNumber(for: b.id) ?? ""
                result = ba < bb
            case .risk:
                result = ForensicManager.assessRisk(for: a).score < ForensicManager.assessRisk(for: b).score
            case .from:
                let fa = a.headers["From"] ?? ""
                let fb = b.headers["From"] ?? ""
                result = fa.localizedCaseInsensitiveCompare(fb) == .orderedAscending
            case .to:
                let ta = a.headers["To"] ?? ""
                let tb = b.headers["To"] ?? ""
                result = ta.localizedCaseInsensitiveCompare(tb) == .orderedAscending
            case .subject:
                let sa = a.headers["Subject"] ?? ""
                let sb = b.headers["Subject"] ?? ""
                result = sa.localizedCaseInsensitiveCompare(sb) == .orderedAscending
            case .date:
                let da = MBOXParser.parseDate(a.headers["Date"] ?? "") ?? .distantPast
                let db = MBOXParser.parseDate(b.headers["Date"] ?? "") ?? .distantPast
                result = da < db
            case .attachments:
                result = a.attachments.count < b.attachments.count
            }
            return forensicSortAscending ? result : !result
        }

        if showCrossPartyFilter && (!crossPartyFrom.isEmpty || !crossPartyTo.isEmpty) {
            return sorted.filter { email in
                let from = (email.headers["From"] ?? "").lowercased()
                let to = (email.headers["To"] ?? "").lowercased()
                let matchFrom = crossPartyFrom.isEmpty || from.contains(crossPartyFrom.lowercased())
                let matchTo = crossPartyTo.isEmpty || to.contains(crossPartyTo.lowercased())
                return matchFrom && matchTo
            }
        }

        return sorted
    }

    private func tagAndAdvance(_ tag: ForensicManager.EvidenceTag, in emails: [MBOXParser.RawEmail]) {
        if selectedEmailIDs.count > 1 {
            for id in selectedEmailIDs {
                forensicManager.tag(id, as: tag)
            }
        } else if let id = selectedEmailIDs.first {
            forensicManager.tag(id, as: tag)
            if let currentIndex = emails.firstIndex(where: { $0.id == id }) {
                let nextUnreviewed = emails[(currentIndex + 1)...].first { forensicManager.tagForEmail($0.id) == .none }
                    ?? emails.first { forensicManager.tagForEmail($0.id) == .none }
                if let next = nextUnreviewed {
                    selectedEmailIDs = [next.id]
                }
            }
        }
    }

    private func forensicTableLayout(emails: [MBOXParser.RawEmail]) -> some View {
        let sorted = forensicSortedEmails(emails)
        return VStack(spacing: 0) {
            forensicActionBar(emails: emails)
            forensicColumnHeader
            Divider()
            List(sorted, id: \.id, selection: $selectedEmailIDs) { email in
                forensicTableRow(for: email)
                    .tag(email.id)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 28)
            .onKeyPress(.init("1")) { tagAndAdvance(.relevant, in: sorted); return .handled }
            .onKeyPress(.init("2")) { tagAndAdvance(.privileged, in: sorted); return .handled }
            .onKeyPress(.init("3")) { tagAndAdvance(.irrelevant, in: sorted); return .handled }
            .onKeyPress(.init("4")) { tagAndAdvance(.flagged, in: sorted); return .handled }
            .onKeyPress(.init("5")) { tagAndAdvance(.suspicious, in: sorted); return .handled }
            .onKeyPress(.init("0")) { tagAndAdvance(.none, in: sorted); return .handled }
            forensicStatusBar(emails: emails)
        }
    }

    // MARK: Forensic Action Bar

    @ViewBuilder
    private func forensicActionBar(emails: [MBOXParser.RawEmail]) -> some View {
        HStack(spacing: Spacing.xSmall) {
            if selectedEmailIDs.count > 1 {
                Text("\(selectedEmailIDs.count) selected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .cornerRadius(3)

                ForEach(ForensicManager.EvidenceTag.allCases.filter { $0 != .none }, id: \.self) { tag in
                    Button {
                        for id in selectedEmailIDs {
                            forensicManager.tag(id, as: tag)
                        }
                        model.applyFilters()
                    } label: {
                        Image(systemName: tag.icon)
                            .font(.system(size: 10))
                            .foregroundColor(tag.color)
                    }
                    .buttonStyle(.plain)
                    .help("Tag all as \(tag.rawValue)")
                }

                Divider().frame(height: 14)
            }

            HStack(spacing: 5) {
                Image(systemName: "keyboard").font(.system(size: 9)).foregroundColor(.secondary)
                Text("Quick Tag:").font(.system(size: 8)).foregroundColor(.secondary)
                inboxKeyBadge("1", label: "Relevant", color: .green)
                inboxKeyBadge("2", label: "Privileged", color: .orange)
                inboxKeyBadge("3", label: "Irrelevant", color: .gray)
                inboxKeyBadge("4", label: "Flagged", color: .red)
                inboxKeyBadge("5", label: "Suspicious", color: .purple)
                inboxKeyBadge("0", label: "Clear", color: .secondary)
            }
            .help("Select an email, then press a number key to quickly tag it as evidence")

            Spacer()

            Button {
                showCrossPartyFilter.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "person.2")
                        .font(.system(size: 9))
                    Text("Party Filter")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(showCrossPartyFilter ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                let ids = forensicManager.qcSample(from: emails, percentage: 0.1)
                qcSampleIDs = Set(ids)
                selectedEmailIDs = Set(ids.prefix(1))
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "dice")
                        .font(.system(size: 9))
                    Text("QC 10%")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Random 10% quality check sample")

            Button {
                forensicManager.runPrivilegeScan(on: emails)
                // Surface the results immediately: the Privileged quick
                // filter shows exactly the rows the scan flagged.
                quickFilterPrivileged = true
                model.applyFilters()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 9))
                    Text("Priv Scan")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(forensicManager.privilegeFlags.isEmpty ? .secondary : .orange)
            }
            .buttonStyle(.plain)
            .help("Auto-detect potentially privileged emails")

            Button {
                showReviewerStats.toggle()
            } label: {
                Image(systemName: "chart.bar")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reviewer statistics")
            .popover(isPresented: $showReviewerStats) {
                reviewerStatsPopover
                    .frame(width: 280)
            }
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 3)
        .background(AppColors.backgroundSecondary.opacity(0.4))

        if showCrossPartyFilter {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "person.2")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                TextField("From contains...", text: $crossPartyFrom)
                    .font(.system(size: 10))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                TextField("To contains...", text: $crossPartyTo)
                    .font(.system(size: 10))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                if !crossPartyFrom.isEmpty || !crossPartyTo.isEmpty {
                    Button("Clear") {
                        crossPartyFrom = ""
                        crossPartyTo = ""
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.xSmall)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.05))
        }
    }

    // MARK: Forensic Column Header (Sortable)

    private func sortableHeader(_ title: String, key: ForensicSortKey, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Button {
            if forensicSortKey == key {
                forensicSortAscending.toggle()
            } else {
                forensicSortKey = key
                forensicSortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if forensicSortKey == key {
                    Image(systemName: forensicSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    private var forensicColumnHeader: some View {
        HStack(spacing: 0) {
            sortableHeader("TAG", key: .tag, width: 68)
                .help("Evidence classification tag — Relevant, Privileged, Flagged, etc.")
            sortableHeader("BATES #", key: .bates, width: 90)
                .help("Bates number — a unique ID assigned to each document for legal tracking")
            sortableHeader("RISK", key: .risk, width: 42, alignment: .center)
                .help("Risk score (0-100) — higher scores indicate more suspicious content")
            Divider().frame(height: 14)
            sortableHeader("FROM", key: .from, width: 130)
                .padding(.leading, 4)
            sortableHeader("TO", key: .to, width: 110)
            sortableHeader("SUBJECT", key: .subject, width: 200)
            Spacer()
            sortableHeader("DATE", key: .date, width: 80, alignment: .trailing)
            sortableHeader("ATT", key: .attachments, width: 24, alignment: .center)
                .help("Number of file attachments")
            Text("STATUS")
                .frame(width: 72, alignment: .center)
                .help("Review status — whether this email has been reviewed or is pending")
        }
        .font(.system(size: 9, weight: .semibold, design: .default))
        .foregroundColor(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 4)
        .background(AppColors.backgroundSecondary.opacity(0.6))
    }

    // MARK: Forensic Table Row

    private func forensicTableRow(for email: MBOXParser.RawEmail) -> some View {
        let tag = forensicManager.tagForEmail(email.id)
        let risk = ForensicManager.assessRisk(for: email)
        let bates = batesManager.getBatesNumber(for: email.id)
        let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
        let to = email.headers["To"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let subject = email.headers["Subject"] ?? "(No Subject)"
        let isReviewed = reviewBatchManager.batches.contains { $0.reviewedIDs.contains(email.id) }
        let isHeld = custodianManager.isUnderLegalHold(email.id)
        let isPrivFlagged = forensicManager.privilegeFlags[email.id] != nil
        let isQCSample = qcSampleIDs.contains(email.id)

        return HStack(spacing: 0) {
            if tag != .none {
                Text(tag.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(tag.color)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(tag.color.opacity(0.12))
                    .cornerRadius(2)
                    .frame(width: 68, alignment: .leading)
            } else if isPrivFlagged {
                HStack(spacing: 1) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 7))
                    Text("Priv?")
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundColor(.orange)
                .frame(width: 68, alignment: .leading)
            } else {
                Text("—")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 68, alignment: .leading)
            }

            if let bates {
                Text(bates)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.purple)
                    .frame(width: 90, alignment: .leading)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 90, alignment: .leading)
            }

            if risk.score > 0 {
                Text("\(risk.score)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(risk.score >= 75 ? .red : risk.score >= 55 ? .orange : risk.score >= 20 ? .yellow : .green)
                    .frame(width: 42, alignment: .center)
            } else {
                Text("0")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.green.opacity(0.6))
                    .frame(width: 42, alignment: .center)
            }

            Text(from)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
                .padding(.leading, 4)

            Text(to)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            Text(subject)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(Self.forensicFormatDate(email.headers["Date"]))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            if !email.attachments.isEmpty {
                Text("\(email.attachments.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 24, alignment: .center)
            } else {
                Text("")
                    .frame(width: 24)
            }

            HStack(spacing: 2) {
                if isHeld {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                }
                if isQCSample {
                    Image(systemName: "dice.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.blue)
                }
                if isReviewed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .frame(width: 72, alignment: .center)
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(isQCSample ? Color.blue.opacity(0.04) : hoveringEmailID == email.id ? AppColors.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(AnimationTiming.fast) {
                hoveringEmailID = isHovering ? email.id : nil
            }
        }
        .contextMenu {
            Button {
                let rawData = email.rawSource.data(using: .utf8) ?? Data()
                let kit = SwiftEmailMessage(rawSource: rawData)
                let kitString = kit.asRFC822String()
                let rawRFC822 = !kitString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kitString : email.rawSource
                activeSheet = .rawSource(rawRFC822)
            } label: {
                Label("View Raw Source", systemImage: "doc.plaintext")
            }

            Divider()

            Menu("Evidence Tag") {
                ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tagOption in
                    Button {
                        forensicManager.tag(email.id, as: tagOption)
                        model.applyFilters()
                    } label: {
                        HStack {
                            Label(tagOption.rawValue, systemImage: tagOption.icon)
                            if forensicManager.tagForEmail(email.id) == tagOption {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if !email.attachments.isEmpty {
                Divider()
                Button {
                    saveAttachmentsForEmail(email)
                } label: {
                    Label("Save Attachments (\(email.attachments.count))", systemImage: "arrow.down.circle")
                }
            }

            Divider()

            Button {
                PlatformClipboard.copyString(email.headers["Subject"] ?? "")
            } label: {
                Label("Copy Subject", systemImage: "doc.on.doc")
            }

            Button {
                PlatformClipboard.copyString(email.headers["From"] ?? "")
            } label: {
                Label("Copy Sender", systemImage: "person.crop.circle")
            }
        }
    }

    // MARK: Forensic Status Bar

    private func forensicStatusBar(emails: [MBOXParser.RawEmail]) -> some View {
        let total = emails.count
        let tagged = emails.filter { forensicManager.tagForEmail($0.id) != .none }.count
        let relevant = emails.filter { forensicManager.tagForEmail($0.id) == .relevant }.count
        let privileged = emails.filter { forensicManager.tagForEmail($0.id) == .privileged }.count
        let flagged = emails.filter { forensicManager.tagForEmail($0.id) == .flagged }.count
        let progress = total > 0 ? Double(tagged) / Double(total) : 0
        let progressPct = Int(progress * 100)

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.small) {
                HStack(spacing: 4) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                        .tint(progress >= 1.0 ? .green : .blue)
                    Text("\(tagged) of \(total) tagged (\(progressPct)%)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .help("Your tagging progress — tag emails using keyboard shortcuts or the evidence tag buttons")

                Divider().frame(height: 12)

                HStack(spacing: 5) {
                    inboxStatusDot(.green, count: relevant, label: "Relevant")
                    inboxStatusDot(.orange, count: privileged, label: "Privileged")
                    inboxStatusDot(.red, count: flagged, label: "Flagged")
                }
                .help("Distribution of your evidence tags across emails")

                if !forensicManager.privilegeFlags.isEmpty {
                    Divider().frame(height: 12)
                    HStack(spacing: 2) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 8))
                        Text("\(forensicManager.privilegeFlags.count) privilege flags")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.orange)
                    .help("Emails auto-detected as potentially privileged (attorney-client, work product, etc.)")
                }

                Spacer()

                if !qcSampleIDs.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "dice.fill")
                            .font(.system(size: 8))
                        Text("\(qcSampleIDs.count) QC samples")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.blue)
                    .help("Quality control sample — random emails selected for review accuracy checking")

                    Button("Clear QC") {
                        qcSampleIDs = []
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal, Spacing.xSmall)
            .padding(.vertical, 3)
            .background(AppColors.backgroundSecondary.opacity(0.4))
        }
    }

    private func inboxStatusDot(_ color: Color, count: Int, label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)").font(.system(size: 8, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 7))
        }
        .foregroundColor(count > 0 ? color : .secondary.opacity(0.5))
    }

    private func inboxKeyBadge(_ key: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .frame(width: 12, height: 12)
                .background(color.opacity(0.15))
                .cornerRadius(2)
            Text(label).font(.system(size: 8))
        }
        .foregroundColor(color)
    }

    // MARK: Reviewer Stats Popover

    private var reviewerStatsPopover: some View {
        let stats = forensicManager.computeReviewerStats()
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Reviewer Statistics")
                .font(.system(size: 12, weight: .bold))

            Divider()

            HStack {
                Text("Total Tagged:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(stats.totalTagged)")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11))

            ForEach(Array(stats.tagDistribution.sorted(by: { $0.value > $1.value })), id: \.key) { tag, count in
                HStack {
                    Image(systemName: tag.icon)
                        .foregroundColor(tag.color)
                        .frame(width: 16)
                    Text(tag.rawValue)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(count)")
                        .fontWeight(.medium)
                }
                .font(.system(size: 10))
            }

            Divider()

            if stats.avgSecondsPerTag > 0 {
                HStack {
                    Text("Avg Time/Tag:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0fs", stats.avgSecondsPerTag))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 11))

                HStack {
                    Text("Est. Rate:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.0f/hr", 3600.0 / stats.avgSecondsPerTag))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 11))
            }

            if stats.privilegeFlagged > 0 {
                HStack {
                    Text("Priv Flagged:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(stats.privilegeFlagged)")
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
                .font(.system(size: 11))
            }
        }
        .padding(Spacing.medium)
    }
    #endif

    // MARK: - Cleanup Mode
    // Part G9: archive-wide storage total (SUM aggregate) and per-sender
    // rollups (bounded GROUP BY) come from the store — the resident preview is
    // never presented as archive stats.
    private var cleanupModeView: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Label("Email Cleanup", systemImage: "trash.circle")
                    .font(Typography.headline)
                Spacer()
                Text(String(format: "%.1f MB total", Double(cleanupTotalSizeBytes) / (1024.0 * 1024.0)))
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(AppColors.primary.opacity(0.1))
                    .cornerRadius(CornerRadius.round)
            }
            .padding(.horizontal, Spacing.small)

            List {
                ForEach(cleanupSenderRollups, id: \.sender) { group in
                    HStack {
                        VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                            Text(group.sender)
                                .font(Typography.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            HStack(spacing: Spacing.small) {
                                Text("\(group.count) emails")
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                                Text("\(group.totalSizeBytes / 1024) KB")
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                                if let date = group.latestDate {
                                    Text("Last: \(Self.cleanupDateFormatter.string(from: date))")
                                        .font(Typography.caption2)
                                        .foregroundColor(AppColors.secondary)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            model.searchText = "from:\(extractEmail(from: group.sender))"
                            showCleanupMode = false
                        } label: {
                            Text("View")
                                .font(Typography.caption1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, Spacing.xxxSmall)
                }
            }
        }
        .task {
            cleanupTotalSizeBytes = (try? await ArchiveAggregateService.shared.totalSizeBytes()) ?? 0
            cleanupSenderRollups = (try? await ArchiveAggregateService.shared.senderRollups(limit: 200)) ?? []
        }
    }

    private static let cleanupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()

    private static let forensicDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy"
        return f
    }()

    static func forensicFormatDate(_ raw: String?) -> String {
        guard let raw, let date = MBOXParser.parseDate(raw) else { return "—" }
        return forensicDateFormatter.string(from: date)
    }

    private func extractEmail(from field: String) -> String {
        if let start = field.firstIndex(of: "<"), let end = field.firstIndex(of: ">"), start < end {
            return String(field[field.index(after: start)..<end])
        }
        return field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)
        let trimmed = String(cleaned.prefix(50)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "email" : trimmed
    }

    @ViewBuilder
    private var threadedListView: some View {
        #if os(iOS)
        List {
            threadedListContent
        }
        #else
        List(selection: $selectedEmailIDs) {
            threadedListContent
        }
        #endif
    }

    private var threadedListContent: some View {
        ForEach(quickFilteredThreads) { thread in
            if thread.count == 1 {
                threadedRow(for: thread.root)
            } else {
                DisclosureGroup {
                    ForEach(Array(thread.replies.enumerated()), id: \.element.id) { index, reply in
                        HStack(spacing: 0) {
                            threadConnector(isLast: index == thread.replies.count - 1)
                            threadedRow(for: reply)
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xSmall) {
                        emailRow(for: thread.root)
                        Text("\(thread.count)")
                            .font(Typography.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, Spacing.xxSmall)
                            .padding(.vertical, 2)
                            .background(AppColors.primary)
                            .cornerRadius(CornerRadius.round)
                    }
                }
                .tag(thread.root.id)
            }
        }
    }

    @ViewBuilder
    private func threadedRow(for email: MBOXParser.RawEmail) -> some View {
        #if os(iOS)
        NavigationLink(value: email.id) {
            emailRow(for: email)
        }
        .padding(.vertical, Spacing.xxxSmall)
        #else
        emailRow(for: email)
            .padding(.vertical, Spacing.xxxSmall)
            .tag(email.id)
        #endif
    }

    private func threadConnector(isLast: Bool) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(AppColors.primary.opacity(0.25))
                    .frame(width: 1)
                    .frame(maxHeight: isLast ? 12 : .infinity)
            }
            .frame(width: 1)
            .padding(.leading, Spacing.xSmall)

            Rectangle()
                .fill(AppColors.primary.opacity(0.25))
                .frame(width: 10, height: 1)

            Circle()
                .fill(AppColors.primary.opacity(0.4))
                .frame(width: 4, height: 4)
        }
        .frame(width: 24)
    }

    private func emailRow(for email: MBOXParser.RawEmail) -> some View {
        #if os(iOS)
        iOSEmailRow(for: email)
        #else
        macOSEmailRow(for: email)
        #endif
    }

    #if os(iOS)
    private func iOSEmailRow(for email: MBOXParser.RawEmail) -> some View {
        EmailRowView(email: email, searchText: model.searchText, showRiskIndicator: forensicManager.isEnabled || personaManager.selectedPersona == .legal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    let rawData = email.rawSource.data(using: .utf8) ?? Data()
                    let kit = SwiftEmailMessage(rawSource: rawData)
                    let kitString = kit.asRFC822String()
                    let rawRFC822 = !kitString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kitString : email.rawSource
                    activeSheet = .rawSource(rawRFC822)
                } label: {
                    Label("View Raw Source", systemImage: "doc.plaintext")
                }

                Button {
                    PlatformClipboard.copyString(email.headers["Subject"] ?? "")
                } label: {
                    Label("Copy Subject", systemImage: "doc.on.doc")
                }

                Button {
                    PlatformClipboard.copyString(email.headers["From"] ?? "")
                } label: {
                    Label("Copy Sender", systemImage: "person.crop.circle")
                }

                Button {
                    let summary = EmailNLPEngine.summarizeEmail(email)
                    PlatformClipboard.copyString(summary)
                } label: {
                    Label("Summarize", systemImage: "sparkles")
                }

                if !email.attachments.isEmpty {
                    Divider()
                    Button {
                        saveAttachmentsForEmail(email)
                    } label: {
                        Label("Save Attachments (\(email.attachments.count))", systemImage: "arrow.down.circle")
                    }
                }

                if forensicManager.isEnabled {
                    Divider()
                    Menu("Evidence Tag") {
                        ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tag in
                            Button {
                                forensicManager.tag(email.id, as: tag)
                                model.applyFilters()
                            } label: {
                                HStack {
                                    Label(tag.rawValue, systemImage: tag.icon)
                                    if forensicManager.tagForEmail(email.id) == tag {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
    }
    #endif

    @ObservedObject private var batesManager = BatesNumberingManager.shared

    private func macOSEmailRow(for email: MBOXParser.RawEmail) -> some View {
        HStack(spacing: Spacing.xSmall) {
            if forensicManager.isEnabled {
                let tag = forensicManager.tagForEmail(email.id)
                if tag != .none {
                    Text(tag.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(tag.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tag.color.opacity(0.12))
                        .cornerRadius(3)
                } else {
                    Image(systemName: "tag")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.4))
                        .help("No evidence tag")
                }

                if let bates = batesManager.getBatesNumber(for: email.id) {
                    Text(bates)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(3)
                        .help("Bates number")
                }
            }

            if model.isPinned(email.id) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
                    .help("Pinned")
            }

            let priority = model.priorityLevel(for: email.id)
            if priority == .high {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.caption2)
                    .foregroundColor(.red)
                    .help("High priority")
            } else if priority == .medium {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(Typography.caption2)
                    .foregroundColor(.orange)
                    .help("Medium priority")
            }

            EmailRowView(email: email, searchText: model.searchText, showRiskIndicator: forensicManager.isEnabled || personaManager.selectedPersona == .legal)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let label = predictiveEngine.predictionLabel(for: email.id) {
                let score = predictiveEngine.predictionScore(for: email.id) ?? 0.5
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(score > 0.7 ? Color.green.opacity(0.15) : score < 0.3 ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                    .foregroundColor(score > 0.7 ? .green : score < 0.3 ? .red : .orange)
                    .cornerRadius(3)
            }

            if custodianManager.isUnderLegalHold(email.id) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .help("Under legal hold")
            }

            Spacer(minLength: Spacing.xSmall)

            emailTagPills(for: email)

            Button {
                let rawData = email.rawSource.data(using: .utf8) ?? Data()
                let kit = SwiftEmailMessage(rawSource: rawData)
                let kitString = kit.asRFC822String()
                let fallback = email.rawSource
                let rawRFC822 = !kitString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kitString : fallback
                activeSheet = .rawSource(rawRFC822)
            } label: {
                Image(systemName: "doc.plaintext")
                    .foregroundColor(AppColors.secondary)
            }
            .buttonStyle(.plain)
            .help("View raw RFC 822 source")
            .accessibilityLabel("View raw source")

            if !email.attachments.isEmpty {
                AttachmentsPopoverButton(attachments: email.attachments)
            }
        }
        .padding(.horizontal, Spacing.xSmall)
        .padding(.vertical, Spacing.xxxSmall)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium)
                .fill(hoveringEmailID == email.id ? AppColors.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .focusRing()
        .onHover { isHovering in
            withAnimation(AnimationTiming.fast) {
                hoveringEmailID = isHovering ? email.id : nil
            }
        }
        .contextMenu {
            #if os(macOS)
            Button {
                let rehydrated = model.visibleEmails.first(where: { $0.id == email.id }) ?? email
                EmailDetailView(email: rehydrated)
                    .openInWindow(title: decodeMIMEHeader(rehydrated.headers["Subject"] ?? "Email"), storeManager: storeManager)
            } label: {
                Label("Open in Window", systemImage: "macwindow")
            }
            #endif

            Button {
                let rawData = email.rawSource.data(using: .utf8) ?? Data()
                let kit = SwiftEmailMessage(rawSource: rawData)
                let kitString = kit.asRFC822String()
                let rawRFC822 = !kitString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kitString : email.rawSource
                activeSheet = .rawSource(rawRFC822)
            } label: {
                Label("View Raw Source", systemImage: "doc.plaintext")
            }

            Divider()

            Button {
                PlatformClipboard.copyString(email.headers["Subject"] ?? "")
            } label: {
                Label("Copy Subject", systemImage: "doc.on.doc")
            }

            Button {
                PlatformClipboard.copyString(email.headers["From"] ?? "")
            } label: {
                Label("Copy Sender", systemImage: "person.crop.circle")
            }

            Divider()

            Button {
                let summary = EmailNLPEngine.summarizeEmail(email)
                PlatformClipboard.copyString(summary)
            } label: {
                Label("Summarize (copy to clipboard)", systemImage: "sparkles")
            }

            if !email.attachments.isEmpty {
                Divider()
                Button {
                    saveAttachmentsForEmail(email)
                } label: {
                    Label("Save Attachments (\(email.attachments.count))", systemImage: "arrow.down.circle")
                }
            }

            if forensicManager.isEnabled {
                Divider()
                Menu("Evidence Tag") {
                    ForEach(ForensicManager.EvidenceTag.allCases, id: \.self) { tag in
                        Button {
                            forensicManager.tag(email.id, as: tag)
                            model.applyFilters()
                        } label: {
                            HStack {
                                Label(tag.rawValue, systemImage: tag.icon)
                                if forensicManager.tagForEmail(email.id) == tag {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .onDrag {
            let data = Data(email.rawSource.utf8)
            let provider = NSItemProvider()
            let filename = sanitizeFilename(email.headers["Subject"] ?? "email") + ".eml"
            provider.suggestedName = filename
            provider.registerDataRepresentation(forTypeIdentifier: UTType.emailMessage.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        #endif
    }

    #if os(iOS)
    private func iOSShareFile(at url: URL) {
        shareItems = [url]
        showShareSheet = true
    }
    #endif

    // MARK: - Email Tag Picker

    private enum EmailQuickTag: String, CaseIterable {
        case none = "—"
        case sent = "Sent"
        case received = "Received"
        case personal = "Personal"
        case transactional = "Transactional"
        case newsletter = "Newsletter"
        case promotional = "Promotional"
        case automated = "Automated"
        case relevant = "Relevant"
        case privileged = "Privileged"
        case irrelevant = "Irrelevant"
        case flagged = "Flagged"
        case suspicious = "Suspicious"
        case positive = "Positive"
        case negative = "Negative"
        case neutral = "Neutral"
        case highPriority = "High Priority"
        case mediumPriority = "Medium Priority"
        case hasAttachment = "Has Attachment"
        case phishing = "Phishing"

        var icon: String {
            switch self {
            case .none: return "tag"
            case .sent: return "arrow.up.circle"
            case .received: return "arrow.down.circle"
            case .personal: return "person.fill"
            case .transactional: return "creditcard"
            case .newsletter: return "newspaper"
            case .promotional: return "megaphone"
            case .automated: return "gearshape"
            case .relevant: return "checkmark.seal.fill"
            case .privileged: return "lock.shield.fill"
            case .irrelevant: return "xmark.circle"
            case .flagged: return "flag.fill"
            case .suspicious: return "exclamationmark.triangle.fill"
            case .positive: return "face.smiling"
            case .negative: return "face.dashed"
            case .neutral: return "minus.circle"
            case .highPriority: return "exclamationmark.triangle.fill"
            case .mediumPriority: return "exclamationmark.circle"
            case .hasAttachment: return "paperclip"
            case .phishing: return "shield.slash"
            }
        }

        var color: Color {
            switch self {
            case .none: return .secondary
            case .sent: return .blue
            case .received: return .teal
            case .personal: return .cyan
            case .transactional: return .indigo
            case .newsletter: return .mint
            case .promotional: return .pink
            case .automated: return .gray
            case .relevant: return .green
            case .privileged: return .orange
            case .irrelevant: return .gray
            case .flagged: return .red
            case .suspicious: return .purple
            case .positive: return .green
            case .negative: return .red
            case .neutral: return .gray
            case .highPriority: return .red
            case .mediumPriority: return .orange
            case .hasAttachment: return .brown
            case .phishing: return .red
            }
        }
    }

    // MARK: - Tag Resolution

    private func aiTags(for email: MBOXParser.RawEmail) -> [EmailQuickTag] {
        var tags: [EmailQuickTag] = []

        let isPhishing = model.phishingEmailIDs.contains(email.id)

        let forensicTag = forensicManager.tagForEmail(email.id)
        if forensicTag != .none {
            switch forensicTag {
            case .relevant: tags.append(.relevant)
            case .privileged: tags.append(.privileged)
            case .irrelevant: tags.append(.irrelevant)
            case .flagged: tags.append(.flagged)
            case .suspicious: tags.append(.suspicious)
            case .none: break
            }
        }

        let priority = model.priorityLevel(for: email.id)
        if priority == .high { tags.append(.highPriority) }
        else if priority == .medium { tags.append(.mediumPriority) }

        if isPhishing {
            tags.append(.phishing)
            tags.append(.suspicious)
        }

        if !isPhishing {
            if let score = model.sentimentScores[email.id] {
                if score > 0.4 { tags.append(.positive) }
                else if score < -0.4 { tags.append(.negative) }
                else { tags.append(.neutral) }
            }

            if let category = model.emailClassifications[email.id] {
                switch category {
                case .personal: tags.append(.personal)
                case .transactional: tags.append(.transactional)
                case .newsletter: tags.append(.newsletter)
                case .promotional: tags.append(.promotional)
                case .automated: tags.append(.automated)
                case .unknown: break
                }
            }
        }

        if tags.isEmpty {
            if email.messageType == "sent" { tags.append(.sent) }
            else if email.messageType == "received" { tags.append(.received) }
            if !email.attachments.isEmpty { tags.append(.hasAttachment) }
        }

        return tags
    }

    private func basicTags(for email: MBOXParser.RawEmail) -> [EmailQuickTag] {
        var tags: [EmailQuickTag] = []
        if email.messageType == "sent" { tags.append(.sent) }
        else if email.messageType == "received" { tags.append(.received) }
        if !email.attachments.isEmpty { tags.append(.hasAttachment) }

        let forensicTag = forensicManager.tagForEmail(email.id)
        if forensicTag != .none {
            switch forensicTag {
            case .relevant: tags.append(.relevant)
            case .privileged: tags.append(.privileged)
            case .irrelevant: tags.append(.irrelevant)
            case .flagged: tags.append(.flagged)
            case .suspicious: tags.append(.suspicious)
            case .none: break
            }
        }
        return tags
    }

    private func activeTags(for email: MBOXParser.RawEmail) -> [EmailQuickTag] {
        var all: [EmailQuickTag] = []
        if enableAIFeatures && aiTagsApplied {
            all.append(contentsOf: aiTags(for: email))
        } else {
            all.append(contentsOf: basicTags(for: email))
        }
        if let manual = manualOverrideTags[email.id], !manual.isEmpty {
            all.append(contentsOf: manual.sorted { $0.rawValue < $1.rawValue })
        }
        return all
    }

    private func autoTagsOnly(for email: MBOXParser.RawEmail) -> [EmailQuickTag] {
        let auto = aiTagsApplied ? aiTags(for: email) : basicTags(for: email)
        let manual = manualOverrideTags[email.id] ?? []
        guard !manual.isEmpty else { return auto }
        return auto.filter { !manual.contains($0) }
    }

    private func manualTagsOnly(for email: MBOXParser.RawEmail) -> [EmailQuickTag] {
        guard let manual = manualOverrideTags[email.id], !manual.isEmpty else { return [] }
        return Array(manual).sorted { $0.rawValue < $1.rawValue }
    }

    private func hasManualOverride(for emailID: UUID) -> Bool {
        guard let manual = manualOverrideTags[emailID] else { return false }
        return !manual.isEmpty
    }

    private func resolveCurrentTag(for email: MBOXParser.RawEmail) -> EmailQuickTag {
        activeTags(for: email).first ?? .none
    }

    // MARK: - Tag Pills (AI/BS/MN badges, dynamic dedup)

    private func tagBadge(_ code: String, color: Color) -> some View {
        Text(code)
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(Capsule())
    }

    private func tagPillLabel(badge: String, badgeColor: Color, tags: [EmailQuickTag]) -> some View {
        let primary = tags.first ?? .none
        let extra = max(0, tags.count - 1)
        return HStack(spacing: 2) {
            tagBadge(badge, color: badgeColor)
            Image(systemName: primary.icon)
                .font(.system(size: 9))
            Text(primary.rawValue)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AppColors.secondary.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
        .foregroundColor(primary.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(primary.color.opacity(0.1))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func emailTagPills(for email: MBOXParser.RawEmail) -> some View {
        let autoTags = autoTagsOnly(for: email)
        let manualTags = manualTagsOnly(for: email)

        HStack(spacing: 3) {
            if enableAIFeatures && aiTagsApplied && !autoTags.isEmpty {
                Menu {
                    Section("AI Tags") {
                        ForEach(autoTags, id: \.self) { tag in
                            Label(tag.rawValue, systemImage: tag.icon)
                        }
                    }
                    Divider()
                    Section {
                        Label("AI can make mistakes. Verify important tags.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                    }
                } label: {
                    tagPillLabel(badge: "AI", badgeColor: AppColors.primary.opacity(0.7), tags: autoTags)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("AI tags: \(autoTags.map(\.rawValue).joined(separator: ", "))")
            } else if !aiTagsApplied && !autoTags.isEmpty {
                Menu {
                    Section("Basic Tags") {
                        ForEach(autoTags, id: \.self) { tag in
                            Label(tag.rawValue, systemImage: tag.icon)
                        }
                    }
                    if enableAIFeatures {
                        Section {
                            Button {
                                aiTagsApplied = true
                            } label: {
                                Label("Apply AI for smarter tags", systemImage: "brain")
                            }
                        }
                    }
                    Divider()
                    Section {
                        Label("Auto-tags may be inaccurate. Use manual tags to correct.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                    }
                } label: {
                    tagPillLabel(badge: "BS", badgeColor: .gray, tags: autoTags)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Basic tags: \(autoTags.map(\.rawValue).joined(separator: ", "))")
            }

            if !manualTags.isEmpty {
                Menu {
                    Section("Manual Tags") {
                        ForEach(manualTags, id: \.self) { tag in
                            Label(tag.rawValue, systemImage: tag.icon)
                        }
                    }
                    Divider()
                    Button {
                        manualOverrideTags[email.id] = nil
                    } label: {
                        Label("Clear Manual Tags", systemImage: "xmark.circle")
                    }
                } label: {
                    tagPillLabel(badge: "MN", badgeColor: .purple, tags: manualTags)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Manual tags: \(manualTags.map(\.rawValue).joined(separator: ", "))")
            }

            manualTagButton(for: email)
        }
    }

    private func manualTagButton(for email: MBOXParser.RawEmail) -> some View {
        let currentManual = manualOverrideTags[email.id] ?? []
        return Menu {
            Section("Category") {
                manualTagToggle(.personal, current: currentManual, email: email)
                manualTagToggle(.transactional, current: currentManual, email: email)
                manualTagToggle(.newsletter, current: currentManual, email: email)
                manualTagToggle(.promotional, current: currentManual, email: email)
                manualTagToggle(.automated, current: currentManual, email: email)
            }
            Section("Sentiment") {
                manualTagToggle(.positive, current: currentManual, email: email)
                manualTagToggle(.negative, current: currentManual, email: email)
                manualTagToggle(.neutral, current: currentManual, email: email)
            }
            if showAdvancedFeatures {
                Section("Evidence") {
                    manualTagToggle(.relevant, current: currentManual, email: email)
                    manualTagToggle(.privileged, current: currentManual, email: email)
                    manualTagToggle(.irrelevant, current: currentManual, email: email)
                    manualTagToggle(.flagged, current: currentManual, email: email)
                    manualTagToggle(.suspicious, current: currentManual, email: email)
                }
            }
            Section("Other") {
                manualTagToggle(.highPriority, current: currentManual, email: email)
                manualTagToggle(.mediumPriority, current: currentManual, email: email)
                manualTagToggle(.phishing, current: currentManual, email: email)
            }
            if !currentManual.isEmpty {
                Divider()
                Button {
                    manualOverrideTags[email.id] = nil
                } label: {
                    Label("Clear All Manual Tags", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "tag.fill")
                .font(.system(size: 10))
                .foregroundColor(currentManual.isEmpty ? AppColors.secondary.opacity(0.5) : .purple)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        #if os(macOS)
        .help("Set manual tags")
        #endif
        .accessibilityLabel("Set manual tags")
    }

    @ViewBuilder
    private func manualTagToggle(_ tag: EmailQuickTag, current: Set<EmailQuickTag>, email: MBOXParser.RawEmail) -> some View {
        Button {
            var tags = manualOverrideTags[email.id] ?? []
            if tags.contains(tag) {
                tags.remove(tag)
            } else {
                tags.insert(tag)
            }
            manualOverrideTags[email.id] = tags.isEmpty ? nil : tags
        } label: {
            HStack {
                Label(tag.rawValue, systemImage: tag.icon)
                if current.contains(tag) {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private func saveAttachmentsForEmail(_ email: MBOXParser.RawEmail) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        #else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var failedCount = 0
        for att in email.attachments {
            guard let source = att.fileURL else { continue }
            do {
                let safeName = att.filename
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: "..", with: "_")
                try FileUtils.copyFile(from: source, to: folder.appendingPathComponent(safeName))
            } catch {
                failedCount += 1
            }
        }
        if failedCount > 0 {
            listExportError = "Failed to save \(failedCount) attachment(s)."
        }
        #if os(iOS)
        if failedCount == 0 {
            iOSShareFile(at: folder)
        }
        #endif
    }

    // MARK: - Download All Attachments
    private var totalAttachments: Int {
        model.visibleEmails.map { $0.attachments.count }.reduce(0, +)
    }
    private static let freeAttachmentLimit = 10
    @AppStorage("freeAttachmentDownloadCount") private var freeAttachmentDownloadCount: Int = 0

    private func downloadAllAttachments() {
            #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save All"

            guard panel.runModal() == .OK, let folderURL = panel.url else { return }
            #else
            let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("all_attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            #endif

            // Part O: streams the current query from the store (bounded
            // batches) and copies attachment files as it goes — the preview
            // array is never the source; premium is unlimited via streaming,
            // not via an Int.max whole-array walk.
            let scope: ArchiveSelectionScope = .query(model.currentArchiveQuery, exclusions: [])
            let cap: Int? = storeManager.isPremium ? nil : max(0, Self.freeAttachmentLimit - freeAttachmentDownloadCount)
            ExportRunCenter.shared.run(title: "Saving attachments") {
                do {
                    let outcome = try await ArchiveExportService.shared.exportAttachments(
                        scope: scope, to: folderURL, maxAttachments: cap,
                        onProgress: { ExportRunCenter.shared.update(done: $0, total: $1) })
                    if !storeManager.isPremium {
                        freeAttachmentDownloadCount += outcome.saved
                    }
                    if outcome.capped {
                        storeManager.showPaywall = true
                        listExportError = "Free limit: saved \(outcome.saved) attachments. Upgrade to Pro for unlimited."
                    }
                    #if os(iOS)
                    if outcome.saved > 0 { iOSShareFile(at: folderURL) }
                    #endif
                } catch is CancellationError {
                    listExportError = "Attachment download cancelled."
                } catch {
                    listExportError = "Failed to save attachments: \(error.localizedDescription)"
                }
            }
        }

    private var personaListTitle: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Evidence"
        case .legal: return "Documents"
        case .itAdmin: return "Messages"
        case .journalist, .personal, .general: return "Emails"
        }
    }

    // MARK: - Export Filtered Emails — THE unified format list
    /// Same formats as the sidebar and the open-email menu, over the CURRENT
    /// filtered query, streamed from the store.
    private var unifiedExportSections: some View {
        UnifiedExportSections(
            scope: { .query(model.currentArchiveQuery, exclusions: []) },
            emlRender: { model.viewModel.exportEmailAsEML($0) },
            emailCount: model.queryTotalCount,
            share: { url in
                #if os(iOS)
                iOSShareFile(at: url)
                #endif
            },
            errorMessage: $listExportError
        )
        .environmentObject(storeManager)
    }

}

// MARK: - Email Row
struct EmailRowView: View {
    let email: MBOXParser.RawEmail
    var searchText: String = ""
    var showRiskIndicator: Bool = false
    @Environment(\.windowSizeClass) private var sizeClass
    @AppStorage("emailListDensity") private var density = "comfortable"
    @AppStorage("showEmailPreviews") private var showPreviews = true

    private var verticalPadding: CGFloat {
        #if os(iOS)
        return Spacing.xSmall
        #else
        switch density {
        case "compact": return Spacing.xxxSmall
        case "spacious": return Spacing.small
        default: return Spacing.xxSmall
        }
        #endif
    }

    private var senderName: String {
        email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    private var riskScore: Int {
        showRiskIndicator ? ForensicManager.assessRisk(for: email).score : 0
    }

    var body: some View {
        #if os(iOS)
        iOSRow
        #else
        macOSRow
        #endif
    }

    #if os(iOS)
    private var iOSRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Sender
            Text(senderName)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(1)

            // Row 2: Subject
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(2)

            // Row 3: Preview
            if showPreviews {
                let previewSource = email.isBodyCompacted ? email.bodyPreview : String(email.plainBody.prefix(150))
                let preview = previewSource.replacingOccurrences(of: "\n", with: " ")
                if !preview.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            // Row 4: Date + metadata
            HStack(spacing: 8) {
                Text(parseDate(email.headers["Date"]))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !email.attachments.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                        Text("\(email.attachments.count)")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }

                if email.messageType == "sent" {
                    HStack(spacing: 2) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 9))
                        Text("Sent")
                            .font(.caption2)
                    }
                    .foregroundColor(.blue)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(email.headers["Subject"] ?? "No Subject"), from \(senderName)")
    }
    #endif

    private var macOSRow: some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            ContactAvatar(name: senderName, size: sizeClass == .compact ? 26 : 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(highlightedText(senderName))
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if riskScore > 20 {
                        HStack(spacing: 2) {
                            Image(systemName: riskScore >= 55 ? "exclamationmark.triangle.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 9))
                            Text("\(riskScore)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(riskScore >= 75 ? .red : riskScore >= 55 ? .orange : .yellow)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background((riskScore >= 75 ? Color.red : riskScore >= 55 ? Color.orange : Color.yellow).opacity(0.1))
                        .cornerRadius(3)
                    }
                    Spacer()
                    Text(parseDate(email.headers["Date"]))
                        .font(.caption)
                        .foregroundColor(AppColors.secondary)
                }

                Text(highlightedText(email.headers["Subject"] ?? "(No Subject)"))
                    .font(.footnote)
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)

                if showPreviews && sizeClass != .compact {
                    let previewSource = email.isBodyCompacted ? email.bodyPreview : String(email.plainBody.prefix(100))
                    let preview = previewSource.replacingOccurrences(of: "\n", with: " ")
                    if !preview.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(highlightedText(preview))
                            .font(.caption)
                            .foregroundColor(AppColors.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(email.headers["Subject"] ?? "No Subject"), from \(senderName)")
    }

    private func highlightedText(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        let lowered = text.lowercased()
        let queryLowered = query.lowercased()
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: queryLowered, range: searchStart..<lowered.endIndex) {
            let attrStart = AttributedString.Index(range.lowerBound, within: result)
            let attrEnd = AttributedString.Index(range.upperBound, within: result)
            if let attrStart, let attrEnd {
                result[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                result[attrStart..<attrEnd].foregroundColor = .primary
            }
            searchStart = range.upperBound
        }
        return result
    }

    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private func parseDate(_ raw: String?) -> String {
        guard let raw = raw, let date = MBOXParser.parseDate(raw) else { return "" }
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return Self.sameYearFormatter.string(from: date)
        }
        return Self.fullDateFormatter.string(from: date)
    }
}

// MARK: - Dismissable Filter Chip
struct DismissableFilterChip: View {
    let label: String
    let icon: String
    var color: Color = .secondary
    @Binding var isActive: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isActive.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(label)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.leading, 10)
                .padding(.trailing, onRemove != nil ? 4 : 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if let onRemove {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        onRemove()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .padding(3)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .accessibilityLabel("Remove \(label) filter")
            }
        }
        .background(isActive ? color : AppColors.backgroundSecondary.opacity(0.8))
        .foregroundColor(isActive ? .white : color)
        .clipShape(Capsule())
        .accessibilityLabel("Filter \(label)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Quick Filter Chip
struct QuickFilterChip: View {
    let label: String
    let icon: String
    @Binding var isActive: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isActive.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? AppColors.primary : AppColors.backgroundSecondary.opacity(0.8))
            .foregroundColor(isActive ? .white : AppColors.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(label)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct AIFilterChip: View {
    let label: String
    let icon: String
    @Binding var isActive: Bool
    var isComputing: Bool = false

    var body: some View {
        Button {
            guard !isComputing else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isActive.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                if isComputing && !isActive {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Image(systemName: "sparkles")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.purple : AppColors.backgroundSecondary.opacity(0.8))
            .foregroundColor(isActive ? .white : .purple.opacity(0.8))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.purple.opacity(isActive ? 0 : 0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isComputing)
        .accessibilityLabel("AI Filter \(label)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Attachments Popover
struct AttachmentsPopoverButton: View {
    #if os(iOS)
    @State private var shareURL: URL?
    @State private var showShare = false
    #endif
    @State private var saveError: String?
    let attachments: [AttachmentMetadata]
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "paperclip")
                .foregroundColor(AppColors.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                HStack {
                    Text("Attachments (\(attachments.count))")
                        .font(Typography.headline)
                    Spacer()
                    Button {
                        showPopover = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(AppColors.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close attachments")
                }
                Divider()
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, att in
                    HStack(spacing: Spacing.xSmall) {
                        Image(systemName: iconForFileType(att.filename))
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.primary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(att.filename.isEmpty ? "Unnamed" : att.filename)
                                .font(Typography.caption1)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(att.mimeType) · \(formatAttachmentSize(att.size))")
                                .font(Typography.caption2)
                                .foregroundColor(AppColors.secondary)
                        }
                        Spacer()
                        if att.fileURL != nil {
                            Button {
                                saveAttachment(att)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.primary)
                            }
                            .buttonStyle(.plain)
                            #if os(macOS)
                            .help(Text(verbatim: "Save \(att.filename)"))
                            #endif
                            .accessibilityLabel("Save \(att.filename)")
                        }
                    }
                }
            }
            .padding(Spacing.small)
            .frame(width: 280)
        }
        #if !os(macOS)
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        #endif
        .alert("Save Failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .accessibilityLabel("\(attachments.count) attachments")
    }

    private func iconForFileType(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx", "csv": return "tablecells"
        case "zip", "gz", "tar", "rar": return "archivebox"
        case "mp3", "wav", "aac": return "music.note"
        case "mp4", "mov", "avi": return "film"
        case "html", "htm": return "globe"
        case "txt", "rtf": return "doc.text"
        default: return "doc"
        }
    }

    private func formatAttachmentSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", kb)
    }

    private func saveAttachment(_ att: AttachmentMetadata) {
        guard let sourceURL = att.fileURL else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = att.filename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                try FileUtils.copyFile(from: sourceURL, to: dest)
            } catch {
                saveError = "Failed to save \(att.filename): \(error.localizedDescription)"
            }
        }
        #else
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(att.filename)
        do {
            try FileUtils.copyFile(from: sourceURL, to: dest)
            shareURL = dest
            // Dismiss the popover first; on iPhone it presents as a sheet and
            // would conflict with the share sheet otherwise.
            showPopover = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300000000)
                showShare = true
            }
        } catch {
            showPopover = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300000000)
                saveError = "Failed to save \(att.filename): \(error.localizedDescription)"
            }
        }
        #endif
    }
}

// MARK: - Raw Source View
struct RawSourceView: View {
    let rawText: String
    @Environment(\.dismiss) private var dismiss
    @State private var highlightedSource: AttributedString?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Label("Raw RFC 822 Source", systemImage: "doc.plaintext")
                        .font(Typography.title2)
                    Text("The original email source including all headers and MIME encoding")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                Spacer()

                Button {
                    PlatformClipboard.copyString(rawText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Copy raw source to clipboard")
                #endif
                .accessibilityLabel("Copy raw source")

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Close")
                #endif
                .accessibilityLabel("Close raw source view")
            }
            .padding(Spacing.medium)

            Divider()
            ScrollView([.vertical, .horizontal]) {
                if let highlighted = highlightedSource {
                    Text(highlighted)
                        .font(Typography.monoBody)
                        .textSelection(.enabled)
                        .padding(Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(rawText)
                        .font(Typography.monoBody)
                        .textSelection(.enabled)
                        .padding(Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(AppColors.backgroundTertiary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Raw email source")
        .task {
            highlightedSource = Self.syntaxHighlight(rawText)
        }
    }

    private static func syntaxHighlight(_ source: String) -> AttributedString {
        var result = AttributedString()
        let lines = source.components(separatedBy: "\n")
        let headerKeyColor = Color.blue
        let headerValueColor = Color.primary
        let boundaryColor = Color.purple
        let quotedColor = Color.orange
        let commentColor = Color.secondary

        var inBody = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inBody && trimmed.isEmpty {
                inBody = true
                result.append(AttributedString("\n"))
                continue
            }

            var attrLine: AttributedString

            if !inBody {
                if let colonRange = line.range(of: ":") {
                    let key = String(line[line.startIndex..<colonRange.lowerBound])
                    let value = String(line[colonRange.upperBound...])
                    var keyAttr = AttributedString(key + ":")
                    keyAttr.foregroundColor = headerKeyColor
                    var valAttr = AttributedString(value)
                    valAttr.foregroundColor = headerValueColor
                    attrLine = keyAttr
                    attrLine.append(valAttr)
                } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    var contAttr = AttributedString(line)
                    contAttr.foregroundColor = headerValueColor
                    attrLine = contAttr
                } else {
                    attrLine = AttributedString(line)
                }
            } else if trimmed.hasPrefix("--") && (trimmed.contains("boundary") || trimmed.count > 20) {
                var boundaryAttr = AttributedString(line)
                boundaryAttr.foregroundColor = boundaryColor
                boundaryAttr.font = .system(.caption, design: .monospaced).bold()
                attrLine = boundaryAttr
            } else if trimmed.hasPrefix(">") {
                var quotedAttr = AttributedString(line)
                quotedAttr.foregroundColor = quotedColor
                attrLine = quotedAttr
            } else if !inBody && (trimmed.hasPrefix("(") || trimmed.hasPrefix(";")) {
                var commentAttr = AttributedString(line)
                commentAttr.foregroundColor = commentColor
                attrLine = commentAttr
            } else if trimmed.hasPrefix("Content-") || trimmed.hasPrefix("MIME-") {
                if let colonRange = line.range(of: ":") {
                    let key = String(line[line.startIndex..<colonRange.lowerBound])
                    let value = String(line[colonRange.upperBound...])
                    var keyAttr = AttributedString(key + ":")
                    keyAttr.foregroundColor = headerKeyColor
                    var valAttr = AttributedString(value)
                    valAttr.foregroundColor = headerValueColor
                    attrLine = keyAttr
                    attrLine.append(valAttr)
                } else {
                    attrLine = AttributedString(line)
                }
            } else {
                attrLine = AttributedString(line)
            }

            result.append(attrLine)
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }
}

// MARK: - Reply Stats View
struct ReplyStatsView: View {
    /// Part G4: reply frequency comes from a bounded SQL GROUP BY over the
    /// store (ArchiveAggregateService.replyRecipientCounts), not a preview-
    /// array walk. The view loads its own data for the given sender.
    let senderEmail: String
    @State private var replyData: [String: Int] = [:]
    @State private var isLoading = true
    /// v1 parity: when no sender address is set, the archive owner is
    /// auto-detected (v1's annotate() did the same with most-common-From),
    /// so the stats populate without any manual setup.
    @State private var resolvedSender: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Label("Reply Frequency", systemImage: "chart.bar.fill")
                    .font(Typography.title2)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Close this stats view")
                #endif
                .accessibilityLabel("Close reply statistics")
            }

            Text("Shows how many emails you sent to each recipient. Longer bars mean more replies.")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)

            Divider()
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Computing reply statistics…")
                        .font(Typography.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if replyData.isEmpty {
                // Say WHY it's empty: reply stats count recipients of emails
                // sent FROM the user's address — different from the sidebar's
                // per-sender counts, and impossible without a sender address.
                EmptyStateView(
                    icon: "chart.bar",
                    title: resolvedSender.isEmpty
                        ? "Couldn't detect your email address"
                        : "No sent emails found",
                    message: resolvedSender.isEmpty
                        ? "Reply statistics count the emails YOU sent to each recipient. mailin couldn't detect your address in this archive \u{2014} enter it in the sidebar's sender field (or Settings \u{25B8} Default Sender)."
                        : "No emails sent from \(resolvedSender) exist in this archive, so there are no reply statistics. (The sidebar's Reply Frequency list is different \u{2014} it counts emails per sender across the whole archive.)"
                )
            } else {
                let sorted = replyData.sorted { $0.value > $1.value }
                let maxCount = sorted.first?.value ?? 1
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        ForEach(sorted, id: \.key) { email, count in
                            HStack {
                                Text(email)
                                    .font(Typography.monoSmall)
                                    .frame(width: 220, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: CornerRadius.small)
                                        .fill(
                                            LinearGradient(
                                                colors: [AppColors.primary, AppColors.primary.opacity(0.6)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(
                                            width: geo.size.width * CGFloat(count) / CGFloat(maxCount),
                                            height: 10
                                        )
                                }
                                .frame(height: 10)
                                Text("\(count)")
                                    .font(Typography.caption1)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.small)
                }
            }
        }
        .padding(Spacing.medium)
        .task {
            var sender = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if sender.isEmpty {
                sender = (try? await SQLiteEmailStore.shared.detectOwnerAddress()) ?? ""
                if !sender.isEmpty {
                    UserDefaults.standard.set(sender, forKey: "defaultSenderEmail")
                }
            }
            resolvedSender = sender
            replyData = (try? await ArchiveAggregateService.shared.replyRecipientCounts(senderEmail: sender)) ?? [:]
            isLoading = false
        }
    }
}
