import SwiftUI

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
    @State private var quickFilterAIImportant = false
    @State private var quickFilterAISuspicious = false
    @State private var quickFilterAINegative = false
    @State private var quickFilterAINewsletter = false
    @State private var showAIPaywall = false
    private static let freeAIFilterLimit = 3
    @AppStorage("freeAIFilterUsageCount") private var aiFilterUsageCount: Int = 0
    @State private var listExportError: String?
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif

    private var quickFilteredEmails: [MBOXParser.RawEmail] {
        model.filteredEmails.filter { email in
            if quickFilterSent && email.messageType != "sent" { return false }
            if quickFilterReceived && email.messageType != "received" { return false }
            if quickFilterAttachments && email.attachments.isEmpty { return false }
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
            if quickFilterHighPriority {
                let score = model.priorityScores[email.id] ?? 0
                if score < 4 { return false }
            }
            if quickFilterHasLinks {
                let body = email.plainBody.lowercased()
                if !body.contains("http://") && !body.contains("https://") && !body.contains("www.") { return false }
            }
            // AI Smart Filters
            if quickFilterAIImportant {
                let score = model.priorityScores[email.id] ?? 0
                if score < 3 { return false }
            }
            if quickFilterAISuspicious {
                if !model.phishingEmailIDs.contains(email.id) { return false }
            }
            if quickFilterAINegative {
                let sentiment = model.sentimentScores[email.id] ?? 0
                if sentiment >= -0.3 { return false }
            }
            if quickFilterAINewsletter {
                let cat = model.emailClassifications[email.id] ?? .unknown
                if cat != .newsletter && cat != .promotional { return false }
            }
            return true
        }
    }

    private var quickFilteredThreads: [EmailThread] {
        let hasQuickFilter = quickFilterSent || quickFilterReceived || quickFilterAttachments || quickFilterFlagged || quickFilterUnreviewed || quickFilterLargeEmails || quickFilterPrivileged || quickFilterHighPriority || quickFilterHasLinks || quickFilterAIImportant || quickFilterAISuspicious || quickFilterAINegative || quickFilterAINewsletter
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

    // MARK: - UI
    var body: some View {
        VStack(spacing: Spacing.xxSmall) {
            headerView
            quickFilterBar
            Divider()
            contentView

            if totalAttachments > 0 || !model.filteredEmails.isEmpty {
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

                        if !model.filteredEmails.isEmpty {
                            Button {
                                exportFilteredJSON()
                            } label: {
                                Label("JSON", systemImage: "square.and.arrow.up")
                                    .font(Typography.caption1)
                            }
                            .buttonStyle(CompactSecondaryButtonStyle())
                            .controlSize(.small)
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .stats:
                ReplyStatsView(replyData: model.replyFrequency(for: model.viewModel.senderEmail))
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            case .rawSource(let rfc822):
                RawSourceView(rawText: rfc822)
                    #if os(macOS)
                    .frame(minWidth: 800, minHeight: 600)
                    #endif
            }
        }

        .sheet(isPresented: $showAnalyticsSheet) {
            EmailAnalyticsView(emails: model.filteredEmails)
        }
        .sheet(isPresented: $showAIPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
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

                if !model.filteredEmails.isEmpty {
                    Text("\(model.filteredEmails.count)")
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
                TextField(model.isNaturalLanguageMode ? "Ask naturally, e.g. \"John's emails from last week with attachments\"" : "Search emails...", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel(model.isNaturalLanguageMode ? "Natural language search" : "Search emails")
                    .accessibilityHint(model.isNaturalLanguageMode ? "Type a natural language query to filter emails" : "Supports operators: from:, to:, subject:, has:attachment, before:, after:")
                    .onChange(of: model.searchText) { _, _ in
                        model.searchTextDidChange()
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
        }
    }

    // MARK: - AI Filter Helpers

    private var hasAnyAIFilter: Bool {
        let cfg = personaManager.config.showQuickFilters
        return cfg.contains(.aiImportant) || cfg.contains(.aiSuspicious) || cfg.contains(.aiNegative) || cfg.contains(.aiNewsletter)
    }

    private var hasAnyQuickFilterActive: Bool {
        quickFilterSent || quickFilterReceived || quickFilterAttachments || quickFilterFlagged || quickFilterUnreviewed || quickFilterLargeEmails || quickFilterPrivileged || quickFilterHighPriority || quickFilterHasLinks || quickFilterAIImportant || quickFilterAISuspicious || quickFilterAINegative || quickFilterAINewsletter
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
                    if personaManager.showQuickFilter(.sent) {
                        QuickFilterChip(label: "Sent", icon: "arrow.up.right", isActive: Binding(
                            get: { quickFilterSent },
                            set: { newValue in
                                quickFilterSent = newValue
                                if newValue { quickFilterReceived = false }
                            }
                        ))
                    }
                    if personaManager.showQuickFilter(.received) {
                        QuickFilterChip(label: "Received", icon: "arrow.down.left", isActive: Binding(
                            get: { quickFilterReceived },
                            set: { newValue in
                                quickFilterReceived = newValue
                                if newValue { quickFilterSent = false }
                            }
                        ))
                    }
                    if personaManager.showQuickFilter(.attachments) {
                        QuickFilterChip(label: "Attachments", icon: "paperclip", isActive: $quickFilterAttachments)
                    }
                    if personaManager.showQuickFilter(.flagged) {
                        QuickFilterChip(label: "Flagged", icon: "flag.fill", isActive: $quickFilterFlagged)
                    }
                    if personaManager.showQuickFilter(.unreviewed) {
                        QuickFilterChip(label: "Unreviewed", icon: "eye.slash", isActive: $quickFilterUnreviewed)
                    }
                    if personaManager.showQuickFilter(.largeEmails) {
                        QuickFilterChip(label: "Large", icon: "arrow.up.circle", isActive: $quickFilterLargeEmails)
                    }
                    if personaManager.showQuickFilter(.privileged) {
                        QuickFilterChip(label: "Privileged", icon: "lock.shield", isActive: $quickFilterPrivileged)
                    }
                    if personaManager.showQuickFilter(.highPriority) {
                        QuickFilterChip(label: "High Priority", icon: "exclamationmark.triangle.fill", isActive: $quickFilterHighPriority)
                    }
                    if personaManager.showQuickFilter(.hasLinks) {
                        QuickFilterChip(label: "Has Links", icon: "link", isActive: $quickFilterHasLinks)
                    }
                    if personaManager.showQuickFilter(.cleanup) {
                        QuickFilterChip(label: "Cleanup", icon: "trash.circle", isActive: $showCleanupMode)
                    }

                    if enableAIFeatures && hasAnyAIFilter {
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 2)

                        if personaManager.showQuickFilter(.aiImportant) {
                            AIFilterChip(label: "Important", icon: "bolt.fill", isActive: aiFilterBinding(for: $quickFilterAIImportant), isComputing: !model.aiFiltersComputed)
                        }
                        if personaManager.showQuickFilter(.aiSuspicious) {
                            AIFilterChip(label: "Suspicious", icon: "exclamationmark.shield.fill", isActive: aiFilterBinding(for: $quickFilterAISuspicious), isComputing: !model.aiFiltersComputed)
                        }
                        if personaManager.showQuickFilter(.aiNegative) {
                            AIFilterChip(label: "Negative", icon: "hand.thumbsdown.fill", isActive: aiFilterBinding(for: $quickFilterAINegative), isComputing: !model.aiFiltersComputed)
                        }
                        if personaManager.showQuickFilter(.aiNewsletter) {
                            AIFilterChip(label: "Newsletters", icon: "newspaper.fill", isActive: aiFilterBinding(for: $quickFilterAINewsletter), isComputing: !model.aiFiltersComputed)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xSmall)
            }

            if hasAnyQuickFilterActive {
                Button {
                    clearAllQuickFilters()
                } label: {
                    Text("Clear")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.primary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Spacing.xSmall)
            }
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
                EmptyStateView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No matching emails",
                    message: "No emails match your current filters. Try widening the date range, selecting more senders, or reducing the minimum reply count."
                )
            } else if model.groupByThread {
                threadedListView
            } else {
                List(emails, id: \.id, selection: $selectedEmailIDs) { email in
                    emailRow(for: email)
                        .padding(.vertical, Spacing.xxxSmall)
                        .tag(email.id)
                }
            }
        }
    }

    // MARK: - Cleanup Mode
    private var cleanupModeView: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Label("Email Cleanup", systemImage: "trash.circle")
                    .font(Typography.headline)
                Spacer()
                Text(String(format: "%.1f MB total", model.totalStorageMB))
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .padding(.horizontal, Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(AppColors.primary.opacity(0.1))
                    .cornerRadius(CornerRadius.round)
            }
            .padding(.horizontal, Spacing.small)

            List {
                ForEach(model.senderGroups) { group in
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
                                Text("\(group.totalSizeKB) KB")
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
    }

    private static let cleanupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()

    private func extractEmail(from field: String) -> String {
        if let start = field.firstIndex(of: "<"), let end = field.firstIndex(of: ">"), start < end {
            return String(field[field.index(after: start)..<end])
        }
        return field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var threadedListView: some View {
        List(selection: $selectedEmailIDs) {
            ForEach(quickFilteredThreads) { thread in
                if thread.count == 1 {
                    emailRow(for: thread.root)
                        .padding(.vertical, Spacing.xxxSmall)
                        .tag(thread.root.id)
                } else {
                    DisclosureGroup {
                        ForEach(Array(thread.replies.enumerated()), id: \.element.id) { index, reply in
                            HStack(spacing: 0) {
                                threadConnector(isLast: index == thread.replies.count - 1)
                                emailRow(for: reply)
                                    .padding(.vertical, Spacing.xxxSmall)
                            }
                            .tag(reply.id)
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
        HStack(spacing: Spacing.xSmall) {
            if forensicManager.isEnabled {
                let tag = forensicManager.tagForEmail(email.id)
                if tag != .none {
                    Image(systemName: tag.icon)
                        .font(.caption2)
                        .foregroundColor(tag.color)
                        #if os(macOS)
                        .help(Text(verbatim: "Evidence: \(tag.rawValue)"))
                        #endif
                }
            }

            let priority = model.priorityLevel(for: email.id)
            if priority == .high {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.caption2)
                    .foregroundColor(.red)
                    #if os(macOS)
                    .help("High priority")
                    #endif
            } else if priority == .medium {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(Typography.caption2)
                    .foregroundColor(.orange)
                    #if os(macOS)
                    .help("Medium priority")
                    #endif
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
                    #if os(macOS)
                    .help("Under legal hold")
                    #endif
            }

            Spacer(minLength: Spacing.xSmall)

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
            #if os(macOS)
            .help("View raw RFC 822 source")
            #endif
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
                EmailDetailView(email: email)
                    .openInWindow(title: decodeMIMEHeader(email.headers["Subject"] ?? "Email"), storeManager: storeManager)
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

    #if os(iOS)
    private func iOSShareFile(at url: URL) {
        shareItems = [url]
        showShareSheet = true
    }
    #endif

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
                try FileUtils.copyFile(from: source, to: folder.appendingPathComponent(att.filename))
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
        model.filteredEmails.map { $0.attachments.count }.reduce(0, +)
    }
    private static let freeAttachmentLimit = 5
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

            var usedNames = Set<String>()
            var savedCount = 0
            let remaining = storeManager.isPremium ? Int.max : max(0, Self.freeAttachmentLimit - freeAttachmentDownloadCount)
            for email in model.filteredEmails {
                for att in email.attachments {
                    if savedCount >= remaining {
                        storeManager.showPaywall = true
                        listExportError = "Free limit: saved \(savedCount) of \(totalAttachments) attachments. Upgrade to Pro for unlimited."
                        #if os(iOS)
                        if savedCount > 0 { iOSShareFile(at: folderURL) }
                        #endif
                        return
                    }
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
                    let destinationURL = folderURL.appendingPathComponent(filename)
                    do {
                        try FileUtils.copyFile(from: sourceURL, to: destinationURL)
                        savedCount += 1
                    } catch {
                        Task { @MainActor in
                            listExportError = "Failed to copy \(att.filename): \(error.localizedDescription)"
                        }
                    }
                }
            }
            if !storeManager.isPremium {
                freeAttachmentDownloadCount += savedCount
            }
            #if os(iOS)
            if savedCount > 0 { iOSShareFile(at: folderURL) }
            #endif
        }

    private var personaListTitle: String {
        switch personaManager.selectedPersona {
        case .forensic: return "Evidence"
        case .legal: return "Documents"
        case .itAdmin: return "Messages"
        case .journalist, .personal, .general: return "Emails"
        }
    }

    // MARK: - Export Filtered Emails as JSON
    private static let freeExportLimit = 10

    private func exportFilteredJSON() {
            let emailsToExport: [MBOXParser.RawEmail]
            if storeManager.isPremium {
                emailsToExport = model.filteredEmails
            } else {
                emailsToExport = Array(model.filteredEmails.prefix(Self.freeExportLimit))
            }
            let exportable = MBOXParser.ExportableParsedMBOXFile(
                emails: emailsToExport.map { $0.asExportable() },
                summary: MBOXParser.summarize(emails: emailsToExport)
            )

            do {
                let data = try JSONEncoder().encode(exportable)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let suggestedName = "filtered_emails_\(formatter.string(from: Date())).json"

                #if os(macOS)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggestedName
                panel.canCreateDirectories = true
                panel.allowedContentTypes = [.json]

                guard panel.runModal() == .OK, let url = panel.url else { return }
                #else
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
                #endif

                try FileUtils.writeData(data, to: url.path)
                if !storeManager.isPremium && model.filteredEmails.count > Self.freeExportLimit {
                    storeManager.showPaywall = true
                    listExportError = "Exported \(Self.freeExportLimit) of \(model.filteredEmails.count) emails. Upgrade to Pro for unlimited export."
                }
                #if os(iOS)
                iOSShareFile(at: url)
                #endif
            } catch {
                listExportError = "Failed to export JSON: \(error.localizedDescription)"
            }
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
        switch density {
        case "compact": return Spacing.xxxSmall
        case "spacious": return Spacing.small
        default: return Spacing.xxSmall
        }
    }

    private var senderName: String {
        email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    private var riskScore: Int {
        showRiskIndicator ? ForensicManager.assessRisk(for: email).score : 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            ContactAvatar(name: senderName, size: sizeClass == .compact ? 26 : 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(highlightedText(senderName))
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if riskScore > 20 {
                        Image(systemName: riskScore >= 55 ? "exclamationmark.triangle.fill" : "exclamationmark.shield.fill")
                            .font(.caption2)
                            .foregroundColor(riskScore >= 55 ? .orange : .yellow)
                            #if os(macOS)
                            .help(Text(verbatim: "Risk score: \(riskScore)/100"))
                            #endif
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
                    let preview = String(email.plainBody.prefix(100)).replacingOccurrences(of: "\n", with: " ")
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
    @State private var saveError: String?
    #endif
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
        #if os(macOS)
        .help(Text(verbatim: "\(attachments.count) attachment(s)"))
        #endif
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
                let alert = NSAlert()
                alert.messageText = "Save Failed"
                alert.informativeText = "Failed to save \(att.filename): \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        #else
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(att.filename)
        do {
            try FileUtils.copyFile(from: sourceURL, to: dest)
            shareURL = dest
            showShare = true
        } catch {
            saveError = "Failed to save \(att.filename): \(error.localizedDescription)"
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
    let replyData: [String: Int]
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
            if replyData.isEmpty {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "No reply data yet",
                    message: "Reply frequency data will appear once mailin finds sent emails in your archive. Make sure your email address is set correctly in the sidebar."
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
    }
}
