import SwiftUI

struct PersonalEmailOrganizerView: View {
    /// Legacy in-memory source. When `v2Source` is provided AND has data,
    /// the view paginates from SwiftData via `v2Source.emails` instead.
    let emails: [MBOXParser.RawEmail]
    var onSkipToInbox: (() -> Void)? = nil
    /// v2 paginated source. Optional — only callers that want the
    /// memory-bounded SwiftData-backed flow pass it.
    var v2Source: PaginatedEmailViewModel? = nil

    /// Effective email list. Prefers `v2Source.emails` when present and
    /// populated; falls back to the legacy `emails` array otherwise.
    private var effectiveEmails: [MBOXParser.RawEmail] {
        if let v2 = v2Source, !v2.emails.isEmpty {
            return v2.emails
        }
        return emails
    }

    // MARK: - State

    @State private var activeTab: OrganizerTab = .overview
    @State private var searchText = ""
    @State private var selectedCategory: EmailCategory?
    @State private var showCleanupWizard = false

    // v3: KG + NLP + Anomaly
    @State private var graph = KnowledgeGraph()
    @State private var kgLoaded = false
    @State private var nlpCategories: [EmailNLPEngine.EmailCategory: Int] = [:]
    @State private var nlpClassified: [UUID: EmailNLPEngine.EmailCategory] = [:]
    @State private var priorities: [EmailNLPEngine.PriorityResult] = []
    @State private var contactInsights: [EmailNLPEngine.ContactInsight] = []
    @State private var anomalies: [AnomalyDetectionEngine.Anomaly] = []
    @State private var hasV3Analysis = false
    @State private var isV3Loading = false

    // v4: AI + Digest + Background
    @State private var aiTriageText = ""
    @State private var isGeneratingTriage = false
    @State private var digestSections: [AIDigestGenerator.DigestSection] = []
    @State private var isGeneratingDigest = false
    @State private var aiCleanupSuggestions = ""
    @State private var isGeneratingCleanup = false
    @ObservedObject private var backgroundManager = BackgroundAnalysisManager.shared

    // Priority dismissals
    @State private var dismissedPriorityIDs: Set<UUID> = []

    // v5: Personal Analysis Features
    @State private var actionItems: [PersonalAnalysisFeatures.ActionItem] = []
    @State private var subscriptions: [PersonalAnalysisFeatures.Subscription] = []
    @State private var contactRelationships: [PersonalAnalysisFeatures.ContactRelationship] = []
    @State private var responseUrgency: [PersonalAnalysisFeatures.ResponseUrgency] = []
    @State private var emailHabits: [PersonalAnalysisFeatures.EmailHabitInsight] = []
    @State private var hasPersonalAnalysis = false
    @State private var isPersonalAnalysisLoading = false
    @StateObject private var coordinator = AnalysisCoordinator()
    @State private var showTutorial = false

    enum OrganizerTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case contacts = "Contacts"
        case categories = "Categories"
        case attachments = "Attachments"
        case activity = "Activity"
        case cleanup = "Cleanup"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: return "house"
            case .contacts: return "person.crop.circle"
            case .categories: return "folder"
            case .attachments: return "paperclip"
            case .activity: return "chart.bar"
            case .cleanup: return "sparkles"
            }
        }
    }

    enum EmailCategory: String, CaseIterable, Identifiable {
        case personal = "Personal"
        case work = "Work"
        case newsletters = "Newsletters"
        case receipts = "Receipts"
        case social = "Social"
        case notifications = "Notifications"
        case other = "Other"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .personal: return "person"
            case .work: return "briefcase"
            case .newsletters: return "newspaper"
            case .receipts: return "receipt"
            case .social: return "bubble.left.and.bubble.right"
            case .notifications: return "bell"
            case .other: return "tray"
            }
        }

        var color: Color {
            switch self {
            case .personal: return .blue
            case .work: return .orange
            case .newsletters: return .green
            case .receipts: return .purple
            case .social: return .pink
            case .notifications: return .yellow
            case .other: return .gray
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            Divider()
            tabContent
        }
        .overlay { if AnalysisCoordinator.isEnabled { AnalysisProgressOverlay(coordinator: coordinator) } }
        .featureTutorial(.personal, key: "personal_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showCleanupWizard) { cleanupWizardSheet }
        .task { await loadV3Data() }
        .task { await loadV4Data() }
        .task { await loadPersonalFeatures() }
    }

    private func loadV4Data() async {
        if digestSections.isEmpty {
            isGeneratingDigest = true
            let sections = await AIDigestGenerator.generateDigest(period: .lastWeek)
            digestSections = sections
            isGeneratingDigest = false
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            if aiTriageText.isEmpty {
                isGeneratingTriage = true
                let result = try? await FoundationModelEngine.triageStructured(effectiveEmails.prefix(50).map { $0 })
                aiTriageText = result?.summary ?? ""
                isGeneratingTriage = false
            }
        }
        #endif
    }

    private func loadV4Cleanup() async {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard aiCleanupSuggestions.isEmpty else { return }
            isGeneratingCleanup = true
            let result = await FoundationModelEngine.enhanceWithAI(
                scope: .all,
                emails: emails,
                context: "Suggest emails to archive, unsubscribe from, or clean up. Focus on newsletters, duplicates, and old automated emails."
            )
            aiCleanupSuggestions = result ?? "AI cleanup unavailable."
            isGeneratingCleanup = false
        }
        #endif
    }

    private func loadV3Data() async {
        let loaded = KnowledgeGraph.load()
        if loaded.nodeCount > 0 { graph = loaded; kgLoaded = true }

        guard !hasV3Analysis else { return }
        isV3Loading = true
        let emailsCopy = effectiveEmails

        guard AnalysisCoordinator.isEnabled else {
            nlpCategories = EmailNLPEngine.classifyAll(emailsCopy)
            var pe: [UUID: EmailNLPEngine.EmailCategory] = [:]
            for e in emailsCopy { pe[e.id] = EmailNLPEngine.classify(e) }
            nlpClassified = pe; priorities = EmailNLPEngine.scoreAllPriorities(emailsCopy)
            contactInsights = EmailNLPEngine.contactInsights(from: emailsCopy, limit: 20)
            anomalies = AnomalyDetectionEngine.detectAnomalies(in: emailsCopy)
            hasV3Analysis = true; isV3Loading = false; return
        }

        coordinator.begin(steps: 10, color: .blue)

        coordinator.advance(step: 1, label: "Classifying emails...")
        guard let cats = await coordinator.runDetached({ EmailNLPEngine.classifyAll(emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 2, label: "Categorizing per email...")
        guard let perEmail = await coordinator.runDetached({
            var pe: [UUID: EmailNLPEngine.EmailCategory] = [:]
            for e in emailsCopy { pe[e.id] = EmailNLPEngine.classify(e) }
            return pe
        }) else { coordinator.finish(); return }

        coordinator.advance(step: 3, label: "Scoring priorities...")
        guard let prio = await coordinator.runDetached({ EmailNLPEngine.scoreAllPriorities(emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 4, label: "Building contact insights...")
        guard let insights = await coordinator.runDetached({ EmailNLPEngine.contactInsights(from: emailsCopy, limit: 20) }) else { coordinator.finish(); return }

        coordinator.advance(step: 5, label: "Detecting anomalies...")
        guard let anom = await coordinator.runDetached({ AnomalyDetectionEngine.detectAnomalies(in: emailsCopy) }) else { coordinator.finish(); return }

        nlpCategories = cats; nlpClassified = perEmail; priorities = prio
        contactInsights = insights; anomalies = anom
        hasV3Analysis = true; isV3Loading = false
    }

    private func loadPersonalFeatures() async {
        while !hasV3Analysis { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard !hasPersonalAnalysis else { return }
        isPersonalAnalysisLoading = true
        let emailsCopy = effectiveEmails

        guard AnalysisCoordinator.isEnabled else {
            actionItems = PersonalAnalysisFeatures.extractActionItems(from: emailsCopy)
            subscriptions = PersonalAnalysisFeatures.detectSubscriptions(in: emailsCopy)
            contactRelationships = PersonalAnalysisFeatures.scoreContactRelationships(emails: emailsCopy, userEmail: nil)
            responseUrgency = PersonalAnalysisFeatures.detectResponseUrgency(emails: emailsCopy)
            emailHabits = PersonalAnalysisFeatures.analyzeEmailHabits(emails: emailsCopy)
            hasPersonalAnalysis = true; isPersonalAnalysisLoading = false; return
        }

        if !coordinator.isActive { coordinator.begin(steps: 10, color: .blue); coordinator.advance(step: 5, label: "") }

        coordinator.advance(step: 6, label: "Extracting action items...")
        guard let items = await coordinator.runDetached({ PersonalAnalysisFeatures.extractActionItems(from: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 7, label: "Detecting subscriptions...")
        guard let subs = await coordinator.runDetached({ PersonalAnalysisFeatures.detectSubscriptions(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 8, label: "Scoring contact relationships...")
        guard let rels = await coordinator.runDetached({ PersonalAnalysisFeatures.scoreContactRelationships(emails: emailsCopy, userEmail: nil) }) else { coordinator.finish(); return }

        coordinator.advance(step: 9, label: "Detecting response urgency...")
        guard let urg = await coordinator.runDetached({ PersonalAnalysisFeatures.detectResponseUrgency(emails: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 10, label: "Analyzing email habits...")
        guard let habits = await coordinator.runDetached({ PersonalAnalysisFeatures.analyzeEmailHabits(emails: emailsCopy) }) else { coordinator.finish(); return }

        actionItems = items; subscriptions = subs; contactRelationships = rels
        responseUrgency = urg; emailHabits = habits
        hasPersonalAnalysis = true; isPersonalAnalysisLoading = false
        coordinator.finish()
    }

    // MARK: - Toolbar

    private var toolBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full").font(.system(size: 12)).foregroundColor(.blue)
            Text("Personal Organizer").font(.system(size: 12, weight: .semibold)).foregroundColor(.blue)

            Divider().frame(height: 14)

            ForEach(OrganizerTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 9))
                        Text(tab.rawValue).font(.system(size: 9, weight: activeTab == tab ? .bold : .medium))
                    }
                    .foregroundColor(activeTab == tab ? .blue : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(activeTab == tab ? Color.blue.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            TextField("Search emails...", text: $searchText)
                .font(.system(size: 10))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            TutorialHelpButton(showTutorial: $showTutorial)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppColors.backgroundSecondary.opacity(0.5))
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .overview:
            overviewView
        case .contacts:
            contactsView
        case .categories:
            categoriesView
        case .attachments:
            attachmentsView
        case .activity:
            activityView
        case .cleanup:
            cleanupView
        }
    }

    // MARK: - Overview

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                welcomeCard

                HStack(spacing: 12) {
                    quickStatCard("Total Emails", value: "\(effectiveEmails.count)", icon: "envelope", color: .blue)
                    quickStatCard("Contacts", value: "\(uniqueContacts.count)", icon: "person.2", color: .green)
                    quickStatCard("Attachments", value: "\(totalAttachments)", icon: "paperclip", color: .brown)
                    quickStatCard("Date Range", value: dateRangeString, icon: "calendar", color: .purple)
                }

                if hasV3Analysis { prioritySection; Divider() }

                if hasPersonalAnalysis && !actionItems.isEmpty { actionItemsSection; Divider() }
                if hasPersonalAnalysis && !responseUrgency.isEmpty { responseUrgencySection; Divider() }

                if !digestSections.isEmpty { weeklyDigestCard; Divider() }
                if !backgroundManager.lastRunFindings.isEmpty { whatsNewCard; Divider() }

                Divider()

                sectionTitle("Your Email at a Glance", icon: "chart.pie", color: .blue)
                let categories = categorizeEmails()
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(categories.sorted(by: { $0.value.count > $1.value.count }), id: \.key) { category, emails in
                        categoryCard(category, count: effectiveEmails.count)
                    }
                }

                Divider()

                sectionTitle("Recent Emails", icon: "clock", color: .orange)
                let recent = effectiveEmails.sorted {
                    (MBOXParser.parseDate($0.headers["Date"] ?? "") ?? .distantPast) >
                    (MBOXParser.parseDate($1.headers["Date"] ?? "") ?? .distantPast)
                }
                ForEach(recent.prefix(10), id: \.id) { email in
                    recentEmailRow(email)
                }

                Divider()

                sectionTitle("Quick Actions", icon: "bolt", color: .yellow)
                HStack(spacing: 12) {
                    quickAction("Find Attachments", icon: "paperclip", color: .brown) { activeTab = .attachments }
                    quickAction("View Contacts", icon: "person.crop.circle", color: .green) { activeTab = .contacts }
                    quickAction("Cleanup Suggestions", icon: "sparkles", color: .purple) { activeTab = .cleanup }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Priority Section (v3)

    private var prioritySection: some View {
        let highPriority = priorities.filter { $0.level == .high && !dismissedPriorityIDs.contains($0.email.id) }
        let medPriority = priorities.filter { $0.level == .medium && !dismissedPriorityIDs.contains($0.email.id) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Action Required", icon: "exclamationmark.triangle", color: .red)
                Spacer()
                if !dismissedPriorityIDs.isEmpty {
                    Button {
                        dismissedPriorityIDs.removeAll()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                            Text("Restore All").font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }

            if highPriority.isEmpty && medPriority.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 14))
                    Text("No urgent items found — you're all caught up!")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    priorityBadge("High", count: highPriority.count, color: .red)
                    priorityBadge("Medium", count: medPriority.count, color: .orange)
                }

                ForEach(highPriority.prefix(5), id: \.email.id) { item in
                    priorityRow(item, color: .red)
                }
                ForEach(medPriority.prefix(3), id: \.email.id) { item in
                    priorityRow(item, color: .orange)
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.03))
        .cornerRadius(10)
    }

    private func priorityBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }

    private func priorityRow(_ item: EmailNLPEngine.PriorityResult, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.email.headers["Subject"] ?? "(No Subject)")
                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(item.reasons.prefix(3).joined(separator: " · "))
                    .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text("Score \(item.score)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .help("Priority score based on urgency words, questions, action requests, reply history, and attachments. High: 5+, Medium: 3-4, Low: 0-2")
            Button {
                dismissedPriorityIDs.insert(item.email.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Dismiss this priority item")
        }
        .padding(6)
        .background(AppColors.backgroundSecondary.opacity(0.2))
        .cornerRadius(4)
    }

    // MARK: - Weekly Digest (v4)

    private var weeklyDigestCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12)).foregroundColor(.teal)
                Text("Weekly Digest").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isGeneratingDigest { ProgressView().controlSize(.small) }
            }
            ForEach(digestSections.prefix(3)) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.system(size: 10, weight: .semibold)).foregroundColor(.teal)
                    ForEach(section.items.prefix(2)) { item in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.priority == .high ? Color.red : item.priority == .medium ? .orange : .blue)
                                .frame(width: 5, height: 5)
                            Text(item.headline).font(.system(size: 9)).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.teal.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - What's New (v4)

    private var whatsNewCard: some View {
        let topFindings = backgroundManager.lastRunFindings
            .sorted { $0.severity > $1.severity }
            .prefix(3)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge").font(.system(size: 12)).foregroundColor(.orange)
                Text("What's New").font(.system(size: 12, weight: .semibold))
            }
            ForEach(Array(topFindings)) { finding in
                HStack(spacing: 6) {
                    Circle()
                        .fill(finding.severity >= 0.7 ? Color.red : finding.severity >= 0.4 ? .orange : .green)
                        .frame(width: 6, height: 6)
                    Text(finding.title).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text(finding.category).font(.system(size: 8)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Welcome Card

    private var welcomeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 28))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Email Archive")
                    .font(.system(size: 16, weight: .bold))
                Text("Explore, organize, and find what you need")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let onSkipToInbox = onSkipToInbox {
                Button(action: onSkipToInbox) {
                    Label("Skip to Email Inbox", systemImage: "tray")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Jump straight to the email list without using the Personal Organizer view")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(colors: [Color.blue.opacity(0.08), Color.blue.opacity(0.02)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
    }

    private func quickStatCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }

    private func categoryCard(_ category: EmailCategory, count: Int) -> some View {
        Button {
            selectedCategory = selectedCategory == category ? nil : category
            activeTab = .categories
        } label: {
            VStack(spacing: 4) {
                Image(systemName: category.icon)
                    .font(.system(size: 16))
                    .foregroundColor(category.color)
                Text("\(count)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(category.color)
                Text(category.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(category.color.opacity(0.05))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func recentEmailRow(_ email: MBOXParser.RawEmail) -> some View {
        HStack(spacing: 8) {
            let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
            Image(systemName: "person.circle")
                .font(.system(size: 16))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(from).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(email.headers["Subject"] ?? "(No Subject)")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text(email.headers["Date"].flatMap { MBOXParser.parseDate($0) }.map { formatRelativeDate($0) } ?? "")
                .font(.system(size: 9)).foregroundColor(.secondary)
            if !email.attachments.isEmpty {
                Image(systemName: "paperclip").font(.system(size: 9)).foregroundColor(.brown)
            }
        }
        .padding(.vertical, 2)
    }

    private func quickAction(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(color)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(color.opacity(0.06))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Contacts View

    private var contactsView: some View {
        let contacts = computeContactStats()
        let filtered = searchText.isEmpty ? contacts : contacts.filter {
            $0.name.lowercased().contains(searchText.lowercased()) ||
            $0.email.lowercased().contains(searchText.lowercased())
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Your Contacts (\(contacts.count))", icon: "person.crop.circle", color: .green)

                if hasPersonalAnalysis && !contactRelationships.isEmpty {
                    contactRelationshipsSection
                    Divider()
                }

                if hasV3Analysis && !contactInsights.isEmpty {
                    contactSentimentOverview
                    Divider()
                }

                if kgLoaded {
                    kgNetworkSummary
                    Divider()
                }

                ForEach(filtered, id: \.email) { contact in
                    contactRow(contact)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Contact Sentiment (v3)

    private var contactSentimentOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contact Mood Tracker").font(.system(size: 11, weight: .semibold)).foregroundColor(.green)
                .help("Shows the overall emotional tone of each contact's emails — are they generally positive, neutral, or negative in their messages to you?")
            ForEach(contactInsights.prefix(10), id: \.address) { insight in
                HStack(spacing: 8) {
                    let name = insight.address.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? insight.address
                    Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(insight.emailCount)").font(.system(size: 9, weight: .bold)).foregroundColor(.blue)
                    sentimentIndicator(insight.avgSentiment)
                    Text(insight.sentimentLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(sentimentColor(insight.avgSentiment))
                        .help("Sentiment ranges from -1.0 (very negative) through 0.0 (neutral) to +1.0 (very positive)")
                }
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.04))
        .cornerRadius(8)
    }

    private func sentimentIndicator(_ score: Double) -> some View {
        Circle()
            .fill(sentimentColor(score))
            .frame(width: 8, height: 8)
    }

    private func sentimentColor(_ score: Double) -> Color {
        if score > 0.4 { return .green }
        if score < -0.4 { return .red }
        return .gray
    }

    // MARK: - KG Network Summary (v3)

    private var kgNetworkSummary: some View {
        let stats = graph.statistics()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Your Email Network").font(.system(size: 11, weight: .semibold)).foregroundColor(.cyan)
                .help("A summary of everyone and everything in your email archive — people, organizations, topics, and how they're all connected")
            HStack(spacing: 12) {
                networkStat("\(stats.people)", label: "People", color: .blue, helpText: "Unique people detected across all emails")
                networkStat("\(stats.orgs)", label: "Organizations", color: .orange, helpText: "Organizations identified from email domains and signatures")
                networkStat("\(stats.topics)", label: "Topics", color: .teal, helpText: "Distinct topics extracted from email subjects and content")
                networkStat("\(stats.edges)", label: "Links", color: .purple, helpText: "Connections between people, organizations, and topics")
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(8)
    }

    private func networkStat(_ value: String, label: String, color: Color, helpText: String = "") -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(helpText.isEmpty ? label : helpText)
    }

    struct ContactInfo: Hashable {
        var name: String
        var email: String
        var count: Int
        var lastDate: Date?
    }

    private func computeContactStats() -> [ContactInfo] {
        var stats: [String: ContactInfo] = [:]
        for email in effectiveEmails {
            let fromFull = email.headers["From"] ?? ""
            let fromEmail = extractEmail(fromFull).lowercased()
            let fromName = fromFull.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? fromEmail
            guard !fromEmail.isEmpty else { continue }
            let date = MBOXParser.parseDate(email.headers["Date"] ?? "")
            var info = stats[fromEmail] ?? ContactInfo(name: fromName, email: fromEmail, count: 0)
            info.count += 1
            if let d = date, info.lastDate == nil || d > info.lastDate! { info.lastDate = d }
            stats[fromEmail] = info
        }
        return stats.values.sorted { $0.count > $1.count }
    }

    private func contactRow(_ contact: ContactInfo) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 36, height: 36)
                Text(String(contact.name.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.green)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(contact.email).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(contact.count) emails").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                if let date = contact.lastDate {
                    Text("Last: \(formatRelativeDate(date))").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(AppColors.backgroundSecondary.opacity(0.2))
        .cornerRadius(6)
    }

    // MARK: - Categories View

    private var categoriesView: some View {
        let categories = categorizeEmails()

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Email Categories", icon: "folder", color: .blue)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    // "All" card to clear category filter
                    Button {
                        selectedCategory = nil
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "tray.2").font(.system(size: 16)).foregroundColor(.blue)
                            Text("\(effectiveEmails.count)").font(.system(size: 14, weight: .bold)).foregroundColor(.blue)
                            Text("All").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedCategory == nil ? Color.blue.opacity(0.15) : Color.blue.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selectedCategory == nil ? Color.blue : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(EmailCategory.allCases) { cat in
                        let count = categories[cat]?.count ?? 0
                        Button {
                            selectedCategory = selectedCategory == cat ? nil : cat
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: cat.icon).font(.system(size: 16)).foregroundColor(cat.color)
                                Text("\(count)").font(.system(size: 14, weight: .bold)).foregroundColor(cat.color)
                                Text(cat.rawValue).font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedCategory == cat ? cat.color.opacity(0.15) : cat.color.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selectedCategory == cat ? cat.color : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selected = selectedCategory, let categoryEmails = categories[selected] {
                    Divider()
                    HStack {
                        sectionTitle("\(selected.rawValue) (\(categoryEmails.count))", icon: selected.icon, color: selected.color)
                        Spacer()
                        Button {
                            selectedCategory = nil
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                Text("Clear Filter").font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(categoryEmails.prefix(30), id: \.id) { email in
                        recentEmailRow(email)
                    }
                    if categoryEmails.count > 30 {
                        Text("... and \(categoryEmails.count - 30) more")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Attachments View

    private var attachmentsView: some View {
        let attachmentEmails = effectiveEmails.filter { !$0.attachments.isEmpty }
            .sorted {
                (MBOXParser.parseDate($0.headers["Date"] ?? "") ?? .distantPast) >
                (MBOXParser.parseDate($1.headers["Date"] ?? "") ?? .distantPast)
            }

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Attachments (\(totalAttachments) files in \(attachmentEmails.count) emails)",
                             icon: "paperclip", color: .brown)

                let typeStats = attachmentTypeStats()
                HStack(spacing: 12) {
                    ForEach(typeStats.prefix(5), id: \.0) { type, count in
                        VStack(spacing: 2) {
                            Text("\(count)").font(.system(size: 14, weight: .bold)).foregroundColor(.brown)
                            Text(type).font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(Color.brown.opacity(0.05))
                        .cornerRadius(4)
                    }
                }

                Divider()

                ForEach(attachmentEmails, id: \.id) { email in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                                .font(.system(size: 10, weight: .medium))
                            Spacer()
                            Text(email.headers["Date"] ?? "").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Text(email.headers["Subject"] ?? "(No Subject)")
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            ForEach(email.attachments, id: \.filename) { att in
                                HStack(spacing: 3) {
                                    Image(systemName: attachmentIcon(att.mimeType)).font(.system(size: 9))
                                    Text(att.filename).font(.system(size: 9)).lineLimit(1)
                                    Text(formatBytes(att.size)).font(.system(size: 8)).foregroundColor(.secondary)
                                }
                                .foregroundColor(.brown)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.brown.opacity(0.08))
                                .cornerRadius(3)
                            }
                        }
                    }
                    .padding(6)
                    .background(AppColors.backgroundSecondary.opacity(0.2))
                    .cornerRadius(4)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Cleanup View

    private var cleanupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Cleanup Suggestions", icon: "sparkles", color: .purple)

                let duplicateCount = countDuplicates()
                let largeEmails = findLargeEmails()
                let noSubject = effectiveEmails.filter { ($0.headers["Subject"] ?? "").isEmpty }

                HStack(spacing: 12) {
                    cleanupCard("Potential Duplicates", value: "\(duplicateCount)", icon: "doc.on.doc", color: .indigo,
                                description: "Emails with identical subjects and senders")
                    cleanupCard("Large Emails", value: "\(largeEmails.count)", icon: "externaldrive", color: .orange,
                                description: "Emails over 100KB in body size")
                    cleanupCard("No Subject", value: "\(noSubject.count)", icon: "text.badge.xmark", color: .red,
                                description: "Emails missing a subject line")
                }

                Divider()

                if !largeEmails.isEmpty {
                    sectionTitle("Largest Emails", icon: "externaldrive", color: .orange)
                    ForEach(largeEmails.prefix(10), id: \.id) { email in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(email.headers["Subject"] ?? "(No Subject)")
                                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(formatBytes(email.plainBody.count + email.htmlBody.count))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                        .padding(6)
                        .background(AppColors.backgroundSecondary.opacity(0.2))
                        .cornerRadius(4)
                    }
                }

                Divider()

                sectionTitle("Storage Breakdown", icon: "chart.pie", color: .blue)
                let totalBodySize = effectiveEmails.reduce(0) { $0 + $1.plainBody.count + $1.htmlBody.count }
                let totalAttSize = effectiveEmails.flatMap { $0.attachments }.reduce(0) { $0 + $1.size }
                HStack(spacing: 20) {
                    VStack {
                        Text(formatBytes(totalBodySize)).font(.system(size: 16, weight: .bold)).foregroundColor(.blue)
                        Text("Email Bodies").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    VStack {
                        Text(formatBytes(totalAttSize)).font(.system(size: 16, weight: .bold)).foregroundColor(.brown)
                        Text("Attachments").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    VStack {
                        Text(formatBytes(totalBodySize + totalAttSize)).font(.system(size: 16, weight: .bold)).foregroundColor(.purple)
                        Text("Total").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                if hasPersonalAnalysis && !subscriptions.isEmpty {
                    Divider()
                    subscriptionManagerSection
                }

                Divider()
                aiCleanupSection
            }
            .padding(16)
        }
    }

    // MARK: - AI Cleanup (v4)

    private var aiCleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.purple)
                Text("AI Cleanup Suggestions").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isGeneratingCleanup {
                    ProgressView().controlSize(.small)
                } else if aiCleanupSuggestions.isEmpty {
                    Button("Generate") { Task { await loadV4Cleanup() } }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.purple)
                        .buttonStyle(.plain)
                }
            }

            if !aiCleanupSuggestions.isEmpty {
                Text(aiCleanupSuggestions)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(10)
                    .textSelection(.enabled)
            } else if !isGeneratingCleanup {
                Text("Tap \"Generate\" to get AI-powered cleanup recommendations.")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.04))
        .cornerRadius(8)
    }

    private func cleanupCard(_ title: String, value: String, icon: String, color: Color, description: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 10, weight: .semibold))
            Text(description).font(.system(size: 8)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Activity View

    private var activityView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Email Activity Heatmap", icon: "chart.bar", color: .blue, tip: "Visualizes when your emails are sent and received — spot your busiest days and peak hours at a glance")
                Text("When your emails were sent and received.")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                dayOfWeekChart
                Divider()
                hourOfDayChart
                Divider()
                topSendersThisMonth
                Divider()
                newsletterUnsubscribeSuggestions

                if hasPersonalAnalysis && !emailHabits.isEmpty {
                    Divider()
                    emailHabitsSection
                }

                if hasV3Analysis && !anomalies.isEmpty {
                    Divider()
                    anomalyOverviewSection
                }
            }
            .padding(16)
        }
    }

    // MARK: - Anomaly Overview (v3)

    private var anomalyOverviewSection: some View {
        let grouped = Dictionary(grouping: anomalies, by: \.type)
        let highCount = anomalies.filter { $0.severity > 0.7 }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Anomalies Detected", icon: "exclamationmark.triangle", color: .orange)
                Spacer()
                if highCount > 0 {
                    Text("\(highCount) high severity")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Array(grouped.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                    let items = grouped[type] ?? []
                    let maxSev = items.map(\.severity).max() ?? 0
                    let sevColor: Color = maxSev > 0.7 ? .red : maxSev > 0.4 ? .orange : .yellow

                    VStack(spacing: 3) {
                        Image(systemName: type.icon).font(.system(size: 12)).foregroundColor(sevColor)
                        Text("\(items.count)").font(.system(size: 12, weight: .bold)).foregroundColor(sevColor)
                        Text(type.rawValue).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(sevColor.opacity(0.06))
                    .cornerRadius(6)
                }
            }

            ForEach(anomalies.filter({ $0.severity > 0.7 }).prefix(3)) { anomaly in
                HStack(spacing: 6) {
                    Image(systemName: anomaly.type.icon).font(.system(size: 9)).foregroundColor(.red)
                    Text(anomaly.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", anomaly.severity * 100))
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.red)
                }
                .padding(5)
                .background(Color.red.opacity(0.04))
                .cornerRadius(4)
            }
        }
    }

    private var dayOfWeekChart: some View {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let counts = computeDayOfWeekCounts()
        let maxCount = counts.max() ?? 1

        return VStack(alignment: .leading, spacing: 6) {
            Text("By Day of Week").font(.system(size: 11, weight: .semibold))
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    VStack(spacing: 2) {
                        Text("\(counts[day])")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.blue)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.3 + 0.7 * Double(counts[day]) / Double(max(1, maxCount))))
                            .frame(height: max(4, CGFloat(counts[day]) / CGFloat(max(1, maxCount)) * 80))
                        Text(days[day])
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
    }

    private var hourOfDayChart: some View {
        let counts = computeHourCounts()
        let maxCount = counts.max() ?? 1

        return VStack(alignment: .leading, spacing: 6) {
            Text("By Hour of Day").font(.system(size: 11, weight: .semibold))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<24, id: \.self) { hour in
                    VStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.purple.opacity(0.2 + 0.8 * Double(counts[hour]) / Double(max(1, maxCount))))
                            .frame(height: max(2, CGFloat(counts[hour]) / CGFloat(max(1, maxCount)) * 60))
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 7))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 80)

            HStack {
                Text("Peak hours: \(peakHoursString(counts))")
                    .font(.system(size: 10)).foregroundColor(.purple)
                Spacer()
            }
        }
    }

    private var topSendersThisMonth: some View {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let recentEmails = effectiveEmails.filter {
            (MBOXParser.parseDate($0.headers["Date"] ?? "") ?? .distantPast) > thirtyDaysAgo
        }
        var senderCounts: [String: Int] = [:]
        for email in recentEmails {
            let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
            senderCounts[from, default: 0] += 1
        }
        let top = senderCounts.sorted { $0.value > $1.value }.prefix(8)

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Top Senders (Last 30 Days)", icon: "person.3", color: .green)
            if top.isEmpty {
                Text("No recent emails found").font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ForEach(Array(top), id: \.key) { sender, count in
                    HStack {
                        Text(sender).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.green)
                    }
                }
            }
        }
    }

    private var newsletterUnsubscribeSuggestions: some View {
        let newsletters = effectiveEmails.filter { email in
            let from = (email.headers["From"] ?? "").lowercased()
            return email.headers["List-Unsubscribe"] != nil ||
                   from.contains("noreply") || from.contains("no-reply") ||
                   from.contains("newsletter") || from.contains("digest")
        }

        var senderCounts: [String: Int] = [:]
        for email in newsletters {
            let from = extractEmail(email.headers["From"] ?? "").lowercased()
            if !from.isEmpty { senderCounts[from, default: 0] += 1 }
        }
        let suggestions = senderCounts.sorted { $0.value > $1.value }.prefix(10)

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Newsletter Senders", icon: "newspaper", color: .orange)
            Text("Automated/newsletter senders by volume. Consider unsubscribing from low-value sources.")
                .font(.system(size: 10)).foregroundColor(.secondary)

            if suggestions.isEmpty {
                Text("No newsletters detected").font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ForEach(Array(suggestions), id: \.key) { sender, count in
                    HStack {
                        Image(systemName: "newspaper").font(.system(size: 9)).foregroundColor(.orange)
                        Text(sender).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text("\(count) emails").font(.system(size: 9, weight: .medium)).foregroundColor(.orange)
                    }
                    .padding(4)
                    .background(Color.orange.opacity(0.04))
                    .cornerRadius(3)
                }
            }
        }
    }

    private func computeDayOfWeekCounts() -> [Int] {
        var counts = Array(repeating: 0, count: 7)
        for email in effectiveEmails {
            if let date = MBOXParser.parseDate(email.headers["Date"] ?? "") {
                let weekday = Calendar.current.component(.weekday, from: date) - 1
                counts[weekday] += 1
            }
        }
        return counts
    }

    private func computeHourCounts() -> [Int] {
        var counts = Array(repeating: 0, count: 24)
        for email in effectiveEmails {
            if let date = MBOXParser.parseDate(email.headers["Date"] ?? "") {
                let hour = Calendar.current.component(.hour, from: date)
                counts[hour] += 1
            }
        }
        return counts
    }

    private func peakHoursString(_ counts: [Int]) -> String {
        let indexed = counts.enumerated().sorted { $0.element > $1.element }
        let top3 = indexed.prefix(3).map { "\($0.offset):00" }
        return top3.joined(separator: ", ")
    }

    // MARK: - Cleanup Wizard Sheet

    private var cleanupWizardSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Email Cleanup Wizard").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Done") { showCleanupWizard = false }
            }
            Text("Review and clean up your email archive.")
                .font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }

    // MARK: - Action Items Section (v5)

    private var actionItemsSection: some View {
        let grouped = Dictionary(grouping: actionItems, by: \.urgency)
        let urgencyOrder: [PersonalAnalysisFeatures.ActionItem.Urgency] = [.immediate, .today, .thisWeek, .someday]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 12)).foregroundColor(.indigo)
                Text("Action Items").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isPersonalAnalysisLoading { ProgressView().controlSize(.small) }
                Text("\(actionItems.count) items")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(urgencyOrder, id: \.rawValue) { urgency in
                    let count = grouped[urgency]?.count ?? 0
                    let color = actionUrgencyColor(urgency)
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text("\(count) \(urgency.rawValue)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(color)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(color.opacity(0.1))
                    .cornerRadius(4)
                }
            }

            ForEach(urgencyOrder, id: \.rawValue) { urgency in
                if let items = grouped[urgency], !items.isEmpty {
                    ForEach(items.prefix(urgency == .immediate ? 5 : 3)) { item in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(actionUrgencyColor(item.urgency))
                                .frame(width: 3, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(item.actionType.rawValue)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(actionTypeBadgeColor(item.actionType))
                                        .cornerRadius(3)
                                    Text(item.sender)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Text(item.text)
                                    .font(.system(size: 10))
                                    .lineLimit(2)
                                if let deadline = item.deadline {
                                    Text("Deadline: \(formatRelativeDate(deadline))")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(.red)
                                }
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(AppColors.backgroundSecondary.opacity(0.2))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.03))
        .cornerRadius(10)
    }

    private func actionUrgencyColor(_ urgency: PersonalAnalysisFeatures.ActionItem.Urgency) -> Color {
        switch urgency {
        case .immediate: return .red
        case .today: return .orange
        case .thisWeek: return .blue
        case .someday: return .gray
        }
    }

    private func actionTypeBadgeColor(_ type: PersonalAnalysisFeatures.ActionItem.ActionType) -> Color {
        switch type {
        case .reply: return .blue
        case .task: return .green
        case .decision: return .purple
        case .payment: return .red
        case .appointment: return .teal
        case .followUp: return .orange
        }
    }

    // MARK: - Response Urgency Section (v5)

    private var responseUrgencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 12)).foregroundColor(.red)
                Text("Needs Response").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(responseUrgency.count) pending")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            ForEach(responseUrgency.prefix(8)) { item in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(urgencyScoreColor(item.urgencyScore), lineWidth: 2)
                            .frame(width: 28, height: 28)
                        Text(String(format: "%.0f%%", item.urgencyScore * 100))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(urgencyScoreColor(item.urgencyScore))
                    }
                    .help("Response urgency based on sender request language, question count, email age, and priority headers")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.email.headers["Subject"] ?? "(No Subject)")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Text(item.reasons.prefix(2).joined(separator: " · "))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.suggestedResponseTime)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(urgencyScoreColor(item.urgencyScore))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(urgencyScoreColor(item.urgencyScore).opacity(0.1))
                        .cornerRadius(4)
                }
                .padding(6)
                .background(AppColors.backgroundSecondary.opacity(0.2))
                .cornerRadius(4)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.03))
        .cornerRadius(10)
    }

    private func urgencyScoreColor(_ score: Double) -> Color {
        if score >= 0.6 { return .red }
        if score >= 0.4 { return .orange }
        if score >= 0.25 { return .yellow }
        return .green
    }

    // MARK: - Contact Relationships Section (v5)

    private var contactRelationshipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.circle").font(.system(size: 12)).foregroundColor(.cyan)
                Text("Relationship Insights").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(contactRelationships.count) contacts scored")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            let relTypes: [PersonalAnalysisFeatures.ContactRelationship.RelationshipType] = [.close, .regular, .acquaintance, .oneWay, .dormant]
            let grouped = Dictionary(grouping: contactRelationships, by: \.relationship)
            HStack(spacing: 8) {
                ForEach(relTypes, id: \.rawValue) { relType in
                    let count = grouped[relType]?.count ?? 0
                    if count > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(relationshipColor(relType)).frame(width: 6, height: 6)
                            Text("\(count) \(relType.rawValue)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(relationshipColor(relType))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(relationshipColor(relType).opacity(0.1))
                        .cornerRadius(4)
                    }
                }
            }

            ForEach(contactRelationships.prefix(10), id: \.id) { contact in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(relationshipColor(contact.relationship).opacity(0.15))
                            .frame(width: 32, height: 32)
                        Text(String(contact.name.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(relationshipColor(contact.relationship))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(contact.name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Text(contact.relationship.rawValue)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(relationshipColor(contact.relationship))
                                .cornerRadius(3)
                        }
                        HStack(spacing: 6) {
                            Text("\(contact.frequency) emails")
                                .font(.system(size: 8)).foregroundColor(.secondary)
                            if !contact.topTopics.isEmpty {
                                Text(contact.topTopics.prefix(3).joined(separator: ", "))
                                    .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.gray.opacity(0.15))
                                    .frame(width: geo.size.width, height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(relationshipColor(contact.relationship))
                                    .frame(width: geo.size.width * contact.importanceScore, height: 4)
                            }
                        }
                        .frame(width: 50, height: 4)
                        sentimentIndicator(contact.avgSentiment)
                            .help("Sentiment ranges from -1.0 (very negative) through 0.0 (neutral) to +1.0 (very positive)")
                    }
                }
                .padding(6)
                .background(AppColors.backgroundSecondary.opacity(0.2))
                .cornerRadius(4)
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(8)
    }

    private func relationshipColor(_ type: PersonalAnalysisFeatures.ContactRelationship.RelationshipType) -> Color {
        switch type {
        case .close: return .green
        case .regular: return .blue
        case .acquaintance: return .gray
        case .oneWay: return .orange
        case .dormant: return .purple
        }
    }

    // MARK: - Subscription Manager Section (v5)

    private var subscriptionManagerSection: some View {
        let catOrder: [PersonalAnalysisFeatures.Subscription.SubscriptionCategory] = [.newsletter, .promotional, .socialMedia, .transactional, .notification, .unknown]
        let grouped = Dictionary(grouping: subscriptions, by: \.category)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "envelope.open.badge.clock").font(.system(size: 12)).foregroundColor(.mint)
                Text("Subscription Manager").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(subscriptions.count) subscriptions")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(catOrder, id: \.rawValue) { cat in
                    let count = grouped[cat]?.count ?? 0
                    if count > 0 {
                        VStack(spacing: 2) {
                            Text("\(count)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(subscriptionCategoryColor(cat))
                            Text(cat.rawValue).font(.system(size: 8)).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(subscriptionCategoryColor(cat).opacity(0.06))
                        .cornerRadius(4)
                    }
                }
            }

            ForEach(subscriptions.prefix(12), id: \.id) { sub in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(sub.senderName)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Text(sub.category.rawValue)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(subscriptionCategoryColor(sub.category))
                                .cornerRadius(3)
                            if sub.hasUnsubscribe {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.red.opacity(0.6))
                            }
                        }
                        HStack(spacing: 6) {
                            Text(sub.senderDomain)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary).lineLimit(1)
                            Text(sub.frequency.rawValue)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(sub.emailCount) emails")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(subscriptionCategoryColor(sub.category))
                        if let last = sub.lastReceived {
                            Text("Last: \(formatRelativeDate(last))")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
                .background(AppColors.backgroundSecondary.opacity(0.2))
                .cornerRadius(4)
            }
        }
        .padding(10)
        .background(Color.mint.opacity(0.04))
        .cornerRadius(8)
    }

    private func subscriptionCategoryColor(_ cat: PersonalAnalysisFeatures.Subscription.SubscriptionCategory) -> Color {
        switch cat {
        case .newsletter: return .blue
        case .promotional: return .orange
        case .socialMedia: return .pink
        case .transactional: return .green
        case .notification: return .yellow
        case .unknown: return .gray
        }
    }

    // MARK: - Email Habits Section (v5)

    private var emailHabitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile").font(.system(size: 12)).foregroundColor(.purple)
                Text("Email Habits").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isPersonalAnalysisLoading { ProgressView().controlSize(.small) }
            }

            ForEach(emailHabits) { insight in
                HStack(spacing: 10) {
                    VStack(spacing: 2) {
                        Text(insight.metric)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(habitCategoryColor(insight.category))
                        Text(insight.category.rawValue)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 60)
                    .padding(6)
                    .background(habitCategoryColor(insight.category).opacity(0.08))
                    .cornerRadius(6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title)
                            .font(.system(size: 10, weight: .semibold))
                        Text(insight.detail)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(6)
                .background(AppColors.backgroundSecondary.opacity(0.2))
                .cornerRadius(4)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.04))
        .cornerRadius(8)
    }

    private func habitCategoryColor(_ category: PersonalAnalysisFeatures.EmailHabitInsight.InsightCategory) -> Color {
        switch category {
        case .timing: return .blue
        case .volume: return .green
        case .responsiveness: return .orange
        case .organization: return .purple
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, icon: String, color: Color, tip: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
            Text(title).font(.system(size: 13, weight: .semibold))
            if tip != nil {
                Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
            }
        }
        .help(tip ?? "")
    }

    private var uniqueContacts: Set<String> {
        Set(effectiveEmails.compactMap { extractEmail($0.headers["From"] ?? "").lowercased() }.filter { !$0.isEmpty })
    }

    private var totalAttachments: Int {
        effectiveEmails.flatMap { $0.attachments }.count
    }

    private var dateRangeString: String {
        let dates = effectiveEmails.compactMap { MBOXParser.parseDate($0.headers["Date"] ?? "") }
        guard let first = dates.min(), let last = dates.max() else { return "N/A" }
        let f = DateFormatter()
        f.dateFormat = "MMM yy"
        return "\(f.string(from: first))-\(f.string(from: last))"
    }

    private func categorizeEmails() -> [EmailCategory: [MBOXParser.RawEmail]] {
        var categories: [EmailCategory: [MBOXParser.RawEmail]] = [:]
        for cat in EmailCategory.allCases { categories[cat] = [] }

        for email in effectiveEmails {
            let from = (email.headers["From"] ?? "").lowercased()
            let subject = (email.headers["Subject"] ?? "").lowercased()
            let headers = email.headers

            if from.contains("noreply") || from.contains("no-reply") || headers["List-Unsubscribe"] != nil ||
               from.contains("newsletter") || from.contains("digest") {
                categories[.newsletters]?.append(email)
            } else if subject.contains("receipt") || subject.contains("invoice") || subject.contains("order confirmation") ||
                      subject.contains("payment") || from.contains("receipt") {
                categories[.receipts]?.append(email)
            } else if from.contains("facebook") || from.contains("twitter") || from.contains("linkedin") ||
                      from.contains("instagram") || from.contains("notification") {
                categories[.social]?.append(email)
            } else if from.contains("alert") || from.contains("notification") || from.contains("automated") ||
                      subject.contains("[alert]") || subject.contains("[notification]") {
                categories[.notifications]?.append(email)
            } else if from.contains(".com") && (subject.contains("meeting") || subject.contains("project") ||
                      subject.contains("deadline") || subject.contains("review") || subject.contains("report")) {
                categories[.work]?.append(email)
            } else {
                categories[.personal]?.append(email)
            }
        }
        return categories
    }

    private func extractEmail(_ raw: String) -> String {
        if let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">") {
            return String(raw[raw.index(after: start)..<end])
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func attachmentIcon(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.contains("pdf") { return "doc.text" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "archivebox" }
        return "doc"
    }

    private func attachmentTypeStats() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for att in effectiveEmails.flatMap({ $0.attachments }) {
            let ext = (att.filename as NSString).pathExtension.lowercased()
            let type = ext.isEmpty ? att.mimeType.components(separatedBy: "/").last ?? "unknown" : ext
            counts[type, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    private func countDuplicates() -> Int {
        var seen: Set<String> = []
        var dupes = 0
        for email in effectiveEmails {
            let key = "\(email.headers["From"] ?? "")|\(email.headers["Subject"] ?? "")|\(email.headers["Date"] ?? "")"
            if seen.contains(key) { dupes += 1 }
            else { seen.insert(key) }
        }
        return dupes
    }

    private func findLargeEmails() -> [MBOXParser.RawEmail] {
        effectiveEmails.filter { $0.plainBody.count + $0.htmlBody.count > 100_000 }
            .sorted { ($0.plainBody.count + $0.htmlBody.count) > ($1.plainBody.count + $1.htmlBody.count) }
    }
}
