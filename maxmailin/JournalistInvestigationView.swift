import SwiftUI

struct JournalistInvestigationView: View {
    let emails: [MBOXParser.RawEmail]
    var v2Source: PaginatedEmailViewModel? = nil

    private var effectiveEmails: [MBOXParser.RawEmail] {
        if let v2 = v2Source, !v2.emails.isEmpty { return v2.emails }
        return emails
    }

    // MARK: - State

    @State private var activeTab: InvestigationTab = .sources
    @State private var selectedContactEmail: String?
    @State private var searchText = ""
    @State private var leads: [Lead] = []
    @State private var newLeadTitle = ""
    @State private var newLeadNotes = ""
    @State private var showExportNotes = false
    @State private var keyQuotes: [KeyQuote] = []
    @State private var bookmarkedEmailIDs: Set<UUID> = []
    @State private var sentimentCache: [UUID: SentimentResult] = [:]
    @State private var hasSentimentAnalysis = false

    // v3: KG + NLP + Anomaly
    @State private var graph = KnowledgeGraph()
    @State private var kgLoaded = false
    @State private var nlpSentiment: [EmailNLPEngine.SentimentResult] = []
    @State private var nlpTopics: [(word: String, count: Int)] = []
    @State private var contactInsights: [EmailNLPEngine.ContactInsight] = []
    @State private var anomalies: [AnomalyDetectionEngine.Anomaly] = []
    @State private var hasV3Analysis = false
    @State private var isV3Loading = false

    // v4: AI + PDF + Digest
    @State private var aiNarrative = ""
    @State private var isGeneratingNarrative = false
    @State private var aiQuotes: [KeyQuote] = []
    @State private var isExtractingQuotes = false
    @State private var digestSections: [AIDigestGenerator.DigestSection] = []
    @State private var showPDFExport = false

    // v5: InvestigationFeatures engine
    @State private var sourceCredibilities: [InvestigationFeatures.SourceCredibility] = []
    @State private var storyLeads: [InvestigationFeatures.StoryLead] = []
    @State private var contradictions: [InvestigationFeatures.Contradiction] = []
    @State private var extractedQuotesNLP: [InvestigationFeatures.ExtractedQuote] = []
    @State private var timelineEvents: [InvestigationFeatures.TimelineEvent] = []
    @State private var hasInvestigationFeatures = false
    @StateObject private var coordinator = AnalysisCoordinator()
    @State private var showTutorial = false

    struct SentimentResult {
        var score: Double // -1 to 1
        var label: String // Positive, Negative, Neutral

        var color: Color {
            if score > 0.2 { return .green }
            if score < -0.2 { return .red }
            return .gray
        }

        var icon: String {
            if score > 0.2 { return "face.smiling" }
            if score < -0.2 { return "exclamationmark.triangle" }
            return "minus.circle"
        }
    }

    enum InvestigationTab: String, CaseIterable, Identifiable {
        case sources = "Sources"
        case timeline = "Timeline"
        case topics = "Topics"
        case leads = "Leads"
        case quotes = "Key Quotes"
        case overview = "Overview"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sources: return "person.3"
            case .timeline: return "calendar.day.timeline.left"
            case .topics: return "text.magnifyingglass"
            case .leads: return "lightbulb"
            case .quotes: return "quote.opening"
            case .overview: return "chart.bar"
            }
        }
    }

    struct Lead: Identifiable {
        let id = UUID()
        var title: String
        var notes: String
        var linkedEmailIDs: [UUID] = []
        var priority: Priority = .medium
        var created: Date = Date()

        enum Priority: String, CaseIterable {
            case high = "High"
            case medium = "Medium"
            case low = "Low"

            var color: Color {
                switch self {
                case .high: return .red
                case .medium: return .orange
                case .low: return .blue
                }
            }
        }
    }

    struct KeyQuote: Identifiable {
        let id = UUID()
        var text: String
        var emailID: UUID
        var from: String
        var date: String
        var tag: String = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            Divider()
            tabContent
        }
        .overlay { if AnalysisCoordinator.isEnabled { AnalysisProgressOverlay(coordinator: coordinator) } }
        .featureTutorial(.journalist, key: "journalist_tutorial_seen", isPresented: $showTutorial)
        .sheet(isPresented: $showExportNotes) { exportNotesSheet }
        .task { await loadV3Data() }
        .task { await loadV4Data() }
        .task { await loadInvestigationFeatures() }
        .sheet(isPresented: $showPDFExport) { pdfExportSheet }
    }

    private func loadV4Data() async {
        if digestSections.isEmpty {
            let sections = await AIDigestGenerator.generateDigest(emails: emails, period: .lastWeek)
            digestSections = sections
        }
    }

    private func generateAINarrative() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard aiNarrative.isEmpty else { return }
            isGeneratingNarrative = true
            Task {
                let result = try? await FoundationModelEngine.generateInsights(emails) { text in
                    aiNarrative = text
                }
                aiNarrative = result ?? "AI narrative unavailable."
                isGeneratingNarrative = false
            }
        }
        #endif
    }

    private func extractAIQuotes() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard aiQuotes.isEmpty else { return }
            isExtractingQuotes = true
            Task {
                let result = await FoundationModelEngine.enhanceWithAI(
                    scope: .investigation,
                    emails: Array(effectiveEmails.prefix(50)),
                    context: "Extract the most newsworthy, impactful, or revealing direct quotes from these emails. Return each quote with attribution."
                )
                if let text = result {
                    let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    for line in lines.prefix(10) {
                        aiQuotes.append(KeyQuote(text: line, emailID: UUID(), from: "AI-extracted", date: ""))
                    }
                }
                isExtractingQuotes = false
            }
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
            let sentiment = EmailNLPEngine.analyzeSentiment(of: emailsCopy)
            nlpTopics = EmailNLPEngine.extractTopics(from: emailsCopy, limit: 25)
            contactInsights = EmailNLPEngine.contactInsights(from: emailsCopy, limit: 20)
            anomalies = AnomalyDetectionEngine.detectAnomalies(in: emailsCopy)
            nlpSentiment = sentiment
            var cache: [UUID: SentimentResult] = [:]
            for r in sentiment { let s = r.score; cache[r.email.id] = SentimentResult(score: s, label: s > 0.2 ? "Positive" : s < -0.2 ? "Negative" : "Neutral") }
            sentimentCache = cache; hasSentimentAnalysis = true; hasV3Analysis = true; isV3Loading = false; return
        }

        coordinator.begin(steps: 10, color: .purple)

        coordinator.advance(step: 1, label: "Analyzing sentiment...")
        guard let sentiment = await coordinator.runDetached({ EmailNLPEngine.analyzeSentiment(of: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 2, label: "Extracting topics...")
        guard let topics = await coordinator.runDetached({ EmailNLPEngine.extractTopics(from: emailsCopy, limit: 25) }) else { coordinator.finish(); return }

        coordinator.advance(step: 3, label: "Building contact insights...")
        guard let insights = await coordinator.runDetached({ EmailNLPEngine.contactInsights(from: emailsCopy, limit: 20) }) else { coordinator.finish(); return }

        coordinator.advance(step: 4, label: "Running anomaly detection...")
        guard let anom = await coordinator.runDetached({ AnomalyDetectionEngine.detectAnomalies(in: emailsCopy) }) else { coordinator.finish(); return }

        nlpSentiment = sentiment; nlpTopics = topics; contactInsights = insights; anomalies = anom
        var cache: [UUID: SentimentResult] = [:]
        for r in sentiment { let s = r.score; cache[r.email.id] = SentimentResult(score: s, label: s > 0.2 ? "Positive" : s < -0.2 ? "Negative" : "Neutral") }
        sentimentCache = cache; hasSentimentAnalysis = true; hasV3Analysis = true; isV3Loading = false
    }

    private func loadInvestigationFeatures() async {
        while !hasV3Analysis { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard !hasInvestigationFeatures else { return }
        let emailsCopy = effectiveEmails
        let graphCopy: KnowledgeGraph? = kgLoaded ? graph : nil
        let anomCopy = anomalies

        guard AnalysisCoordinator.isEnabled else {
            sourceCredibilities = InvestigationFeatures.scoreSourceCredibility(emails: emailsCopy, graph: graphCopy)
            storyLeads = InvestigationFeatures.detectStoryLeads(emails: emailsCopy, anomalies: anomCopy, graph: graphCopy)
            contradictions = InvestigationFeatures.detectContradictions(in: emailsCopy)
            extractedQuotesNLP = InvestigationFeatures.extractQuotes(from: emailsCopy)
            timelineEvents = InvestigationFeatures.extractTimelineEvents(from: emailsCopy)
            hasInvestigationFeatures = true; return
        }

        if !coordinator.isActive { coordinator.begin(steps: 10, color: .purple); coordinator.advance(step: 4, label: "") }

        coordinator.advance(step: 5, label: "Scoring source credibility...")
        guard let creds = await coordinator.runDetached({ InvestigationFeatures.scoreSourceCredibility(emails: emailsCopy, graph: graphCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 6, label: "Detecting story leads...")
        guard let leads = await coordinator.runDetached({ InvestigationFeatures.detectStoryLeads(emails: emailsCopy, anomalies: anomCopy, graph: graphCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 7, label: "Finding contradictions...")
        guard let contras = await coordinator.runDetached({ InvestigationFeatures.detectContradictions(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 8, label: "Extracting key quotes...")
        guard let quotes = await coordinator.runDetached({ InvestigationFeatures.extractQuotes(from: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 9, label: "Building event timeline...")
        guard let events = await coordinator.runDetached({ InvestigationFeatures.extractTimelineEvents(from: emailsCopy) }) else { coordinator.finish(); return }

        sourceCredibilities = creds; storyLeads = leads; contradictions = contras
        extractedQuotesNLP = quotes; timelineEvents = events
        hasInvestigationFeatures = true
        coordinator.finish()
    }

    // MARK: - Toolbar

    private var toolBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "newspaper").font(.system(size: 12)).foregroundColor(.purple)
            Text("Investigation Workbench").font(.system(size: 12, weight: .semibold)).foregroundColor(.purple)

            Divider().frame(height: 14)

            ForEach(InvestigationTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 9))
                        Text(tab.rawValue).font(.system(size: 9, weight: activeTab == tab ? .bold : .medium))
                    }
                    .foregroundColor(activeTab == tab ? .purple : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(activeTab == tab ? Color.purple.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            TextField("Search...", text: $searchText)
                .font(.system(size: 10))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Button { runSentimentAnalysis() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "face.smiling").font(.system(size: 9))
                    Text("Sentiment").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(hasSentimentAnalysis ? .green : .purple)
            }
            .buttonStyle(.plain)

            Button { showPDFExport = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: "doc.text").font(.system(size: 9))
                    Text("PDF").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.purple)
            }
            .buttonStyle(.plain)

            Button { showExportNotes = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 9))
                    Text("Export Notes").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

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
        case .sources:
            sourcesView
        case .timeline:
            timelineView
        case .topics:
            topicsView
        case .leads:
            leadsView
        case .quotes:
            quotesView
        case .overview:
            overviewView
        }
    }

    // MARK: - Sources View

    private var sourcesView: some View {
        let contacts = computeContactStats()
        let filtered = searchText.isEmpty ? contacts : contacts.filter {
            $0.email.lowercased().contains(searchText.lowercased()) ||
            $0.name.lowercased().contains(searchText.lowercased())
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Source Network (\(contacts.count) contacts)", icon: "person.3", color: .purple)

                Text("Contacts ranked by communication frequency. Click to see email history.")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                if kgLoaded { kgSourceNetwork; Divider() }

                if hasV3Analysis && !contactInsights.isEmpty {
                    nlpContactSentimentPanel
                    Divider()
                }

                if hasInvestigationFeatures && !sourceCredibilities.isEmpty {
                    sourceCredibilitySection
                    Divider()
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(filtered, id: \.email) { contact in
                        sourceCard(contact)
                    }
                }

                if let selected = selectedContactEmail {
                    Divider()
                    sectionTitle("Emails involving \(selected)", icon: "envelope", color: .purple)
                    let contactEmails = effectiveEmails.filter {
                        ($0.headers["From"] ?? "").lowercased().contains(selected.lowercased()) ||
                        ($0.headers["To"] ?? "").lowercased().contains(selected.lowercased()) ||
                        ($0.headers["Cc"] ?? "").lowercased().contains(selected.lowercased())
                    }
                    ForEach(contactEmails, id: \.id) { email in
                        emailSnippet(email)
                    }
                }
            }
            .padding(12)
        }
    }

    struct ContactStat: Hashable {
        var name: String
        var email: String
        var sentCount: Int
        var receivedCount: Int
        var totalCount: Int
        var firstSeen: Date?
        var lastSeen: Date?
    }

    private func computeContactStats() -> [ContactStat] {
        var stats: [String: ContactStat] = [:]

        for email in effectiveEmails {
            let fromFull = email.headers["From"] ?? ""
            let fromEmail = extractEmail(fromFull).lowercased()
            let fromName = fromFull.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? fromEmail
            let date = MBOXParser.parseDate(email.headers["Date"] ?? "")

            if !fromEmail.isEmpty {
                var stat = stats[fromEmail] ?? ContactStat(name: fromName, email: fromEmail, sentCount: 0, receivedCount: 0, totalCount: 0)
                stat.sentCount += 1
                stat.totalCount += 1
                if let d = date {
                    if stat.firstSeen == nil || d < stat.firstSeen! { stat.firstSeen = d }
                    if stat.lastSeen == nil || d > stat.lastSeen! { stat.lastSeen = d }
                }
                stats[fromEmail] = stat
            }

            for field in ["To", "Cc"] {
                let recipients = (email.headers[field] ?? "").components(separatedBy: ",")
                for recipient in recipients {
                    let recEmail = extractEmail(recipient).lowercased()
                    let recName = recipient.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? recEmail
                    guard !recEmail.isEmpty else { continue }
                    var stat = stats[recEmail] ?? ContactStat(name: recName, email: recEmail, sentCount: 0, receivedCount: 0, totalCount: 0)
                    stat.receivedCount += 1
                    stat.totalCount += 1
                    stats[recEmail] = stat
                }
            }
        }

        return stats.values.sorted { $0.totalCount > $1.totalCount }
    }

    private func sourceCard(_ contact: ContactStat) -> some View {
        Button {
            selectedContactEmail = contact.email
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(contact.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(contact.email).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(contact.totalCount)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.purple)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up").font(.system(size: 7))
                        Text("Sent \(contact.sentCount)").font(.system(size: 8))
                    }
                    .foregroundColor(.green)
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down").font(.system(size: 7))
                        Text("Received \(contact.receivedCount)").font(.system(size: 8))
                    }
                    .foregroundColor(.blue)

                    let credibility = sourceCredibility(contact)
                    HStack(spacing: 2) {
                        Image(systemName: credibility.icon).font(.system(size: 7))
                        Text(credibility.label).font(.system(size: 8))
                    }
                    .foregroundColor(credibility.color)

                    Spacer()
                    if let first = contact.firstSeen, let last = contact.lastSeen {
                        Text("\(formatShortDate(first)) — \(formatShortDate(last))")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedContactEmail == contact.email ? Color.purple.opacity(0.1) : AppColors.backgroundSecondary.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selectedContactEmail == contact.email ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - KG Source Network (v3)

    private var kgSourceNetwork: some View {
        let topPeople = graph.topNodes(by: .person, limit: 10)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Mapped Source Connections").font(.system(size: 11, weight: .semibold)).foregroundColor(.cyan)
                .help("People and organizations automatically mapped from your email archive — shows who is connected to whom")
            if topPeople.isEmpty {
                Text("No connections mapped yet — import emails to build the relationship map.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ForEach(topPeople, id: \.id) { person in
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle").font(.system(size: 10)).foregroundColor(.blue)
                        Text(person.label).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer()
                        let neighbors = graph.neighbors(of: person.id, type: .communicatesWith)
                        if !neighbors.isEmpty {
                            Text("\(neighbors.count) connections")
                                .font(.system(size: 8)).foregroundColor(.purple)
                        }
                        Text("Weight: \(String(format: "%.0f", person.weight))")
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                            .help("Communication frequency weight — higher values indicate more frequent correspondence")
                    }
                }
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - NLP Contact Sentiment (v3)

    private var nlpContactSentimentPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source Sentiment Analysis").font(.system(size: 11, weight: .semibold)).foregroundColor(.green)
                .help("Analyzes the emotional tone of each contact's emails — positive, negative, or neutral — to spot mood changes or tension")
            ForEach(contactInsights.prefix(10), id: \.address) { insight in
                HStack(spacing: 6) {
                    let name = insight.address.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? insight.address
                    Text(name).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text("\(insight.emailCount)").font(.system(size: 9, weight: .bold)).foregroundColor(.blue)
                    Circle()
                        .fill(insight.avgSentiment > 0.4 ? Color.green : insight.avgSentiment < -0.4 ? Color.red : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(insight.sentimentLabel).font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Source Credibility (InvestigationFeatures)

    private var sourceCredibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source Credibility Analysis").font(.system(size: 11, weight: .semibold)).foregroundColor(.indigo)
            Text("Credibility scored by how consistent, responsive, long-term, and well-connected each source is.")
                .font(.system(size: 9)).foregroundColor(.secondary)

            ForEach(Array(sourceCredibilities.prefix(12))) { cred in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: credibilityIcon(cred.overallScore))
                            .font(.system(size: 10))
                            .foregroundColor(credibilityColor(cred.overallScore))
                        Text(cred.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", cred.overallScore * 100))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(credibilityColor(cred.overallScore))
                            .help("Source credibility based on consistency, volume, longevity, reciprocity, topic diversity, and network position")
                        Text("\(cred.emailCount) emails").font(.system(size: 8)).foregroundColor(.secondary)
                        Text("\(cred.topicDiversity) topics").font(.system(size: 8)).foregroundColor(.secondary)
                    }

                    HStack(spacing: 4) {
                        ForEach(Array(cred.factors.prefix(4)), id: \.name) { factor in
                            HStack(spacing: 2) {
                                Text(factor.name).font(.system(size: 7, weight: .medium))
                                Text(String(format: "%.0f", factor.score * 100))
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(credibilityColor(factor.score))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(credibilityColor(factor.score).opacity(0.08))
                            .cornerRadius(3)
                        }
                        Spacer()
                        if let rt = cred.avgResponseTime {
                            Text("Avg resp: \(formatDuration(rt))")
                                .font(.system(size: 7)).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
                .background(AppColors.backgroundSecondary.opacity(0.2))
                .cornerRadius(5)
            }
        }
        .padding(10)
        .background(Color.indigo.opacity(0.04))
        .cornerRadius(8)
    }

    private func credibilityIcon(_ score: Double) -> String {
        if score >= 0.7 { return "checkmark.seal.fill" }
        if score >= 0.4 { return "checkmark.seal" }
        return "questionmark.circle"
    }

    private func credibilityColor(_ score: Double) -> Color {
        if score >= 0.7 { return .green }
        if score >= 0.4 { return .orange }
        return .red
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86400)
    }

    // MARK: - Timeline View

    private var timelineView: some View {
        let grouped = groupEmailsByMonth()

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Email Timeline", icon: "calendar.day.timeline.left", color: .purple)

                if hasInvestigationFeatures && !timelineEvents.isEmpty {
                    timelineEventsSection
                    Divider()
                }

                ForEach(grouped, id: \.0) { month, monthEmails in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(month)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.purple)
                            Spacer()
                            Text("\(monthEmails.count) emails")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.purple.opacity(0.05))
                        .cornerRadius(4)

                        ForEach(monthEmails.prefix(20), id: \.id) { email in
                            timelineRow(email)
                        }
                        if monthEmails.count > 20 {
                            Text("... and \(monthEmails.count - 20) more")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Timeline Events (InvestigationFeatures)

    private var timelineEventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Key Events Detected", icon: "flag.fill", color: .teal)
            Text("Automatically detected events: announcements, decisions, meetings, deadlines, and incidents.")
                .font(.system(size: 9)).foregroundColor(.secondary)

            ForEach(Array(timelineEvents.prefix(20))) { event in
                timelineEventCard(event)
            }
        }
        .padding(10)
        .background(Color.teal.opacity(0.04))
        .cornerRadius(8)
    }

    private func timelineEventCard(_ event: InvestigationFeatures.TimelineEvent) -> some View {
        let icon = eventTypeIcon(event.eventType)
        let color = eventTypeColor(event.eventType)
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 1, height: 16)
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.eventType.rawValue)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(color))
                    Spacer()
                    Text(event.date, style: .date)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(event.summary)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                if !event.entities.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(event.entities.prefix(4)), id: \.self) { entity in
                            Text(entity)
                                .font(.system(size: 7))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.teal.opacity(0.1))
                                .cornerRadius(2)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(AppColors.backgroundSecondary.opacity(0.2))
        .cornerRadius(5)
    }

    private func eventTypeIcon(_ type: InvestigationFeatures.TimelineEvent.EventType) -> String {
        switch type {
        case .announcement: return "megaphone.fill"
        case .decision: return "checkmark.circle.fill"
        case .meeting: return "person.3.fill"
        case .deadline: return "clock.badge.exclamationmark"
        case .incident: return "exclamationmark.triangle.fill"
        case .communication: return "envelope.fill"
        }
    }

    private func eventTypeColor(_ type: InvestigationFeatures.TimelineEvent.EventType) -> Color {
        switch type {
        case .announcement: return .blue
        case .decision: return .green
        case .meeting: return .purple
        case .deadline: return .orange
        case .incident: return .red
        case .communication: return .gray
        }
    }

    private func timelineRow(_ email: MBOXParser.RawEmail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Circle()
                    .fill(bookmarkedEmailIDs.contains(email.id) ? Color.purple : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 1, height: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text(email.headers["Date"] ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button {
                        if bookmarkedEmailIDs.contains(email.id) { bookmarkedEmailIDs.remove(email.id) }
                        else { bookmarkedEmailIDs.insert(email.id) }
                    } label: {
                        Image(systemName: bookmarkedEmailIDs.contains(email.id) ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 9))
                            .foregroundColor(bookmarkedEmailIDs.contains(email.id) ? .purple : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 4) {
                    Text(email.headers["Subject"] ?? "(No Subject)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let sentiment = sentimentCache[email.id] {
                        Image(systemName: sentiment.icon)
                            .font(.system(size: 8))
                            .foregroundColor(sentiment.color)
                    }
                }
            }
        }
    }

    private func groupEmailsByMonth() -> [(String, [MBOXParser.RawEmail])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        var groups: [String: [MBOXParser.RawEmail]] = [:]
        var sortDates: [String: Date] = [:]

        for email in effectiveEmails {
            let date = MBOXParser.parseDate(email.headers["Date"] ?? "")
            let key = date.map { formatter.string(from: $0) } ?? "Unknown Date"
            groups[key, default: []].append(email)
            if let d = date, sortDates[key] == nil || d > sortDates[key]! {
                sortDates[key] = d
            }
        }

        return groups.sorted { (sortDates[$0.key] ?? .distantPast) > (sortDates[$1.key] ?? .distantPast) }
    }

    // MARK: - Topics View

    private var topicsView: some View {
        let topics: [(String, Int, [String])] = hasV3Analysis && !nlpTopics.isEmpty
            ? nlpTopics.map { ($0.word.capitalized, $0.count, []) }
            : extractTopics()

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Topic Discovery", icon: "text.magnifyingglass", color: .purple)
                Text(hasV3Analysis ? "Topics automatically extracted from email content using advanced text analysis." : "Topics extracted from email subject lines.")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                if isV3Loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing email topics...").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }

                ForEach(topics, id: \.0) { topic, count, sampleSubjects in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.purple)
                            Text(topic)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(count) mentions")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.purple)
                        }

                        ForEach(sampleSubjects.prefix(3), id: \.self) { subject in
                            Text("  \(subject)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(8)
                    .background(AppColors.backgroundSecondary.opacity(0.3))
                    .cornerRadius(6)
                }

                if hasV3Analysis && !anomalies.isEmpty {
                    Divider()
                    anomalySuggestedLeads
                }

                if hasInvestigationFeatures && !contradictions.isEmpty {
                    Divider()
                    contradictionsSection
                }
            }
            .padding(12)
        }
    }

    // MARK: - Contradictions (InvestigationFeatures)

    private var contradictionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Contradictions Detected", icon: "arrow.left.arrow.right", color: .red)
            Text("Claims from different senders or dates that appear to contradict each other.")
                .font(.system(size: 9)).foregroundColor(.secondary)

            ForEach(Array(contradictions.prefix(8))) { contradiction in
                contradictionCard(contradiction)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.02))
        .cornerRadius(8)
    }

    private func contradictionCard(_ contradiction: InvestigationFeatures.Contradiction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(contradiction.topic.capitalized)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.red.opacity(0.7)))
                Spacer()
                let simText = String(format: "%.0f%%", contradiction.similarity * 100)
                Text("Similarity: \(simText)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                    .help("Semantic similarity between the two claims — higher similarity with opposing meaning suggests a stronger contradiction")
            }

            HStack(alignment: .top, spacing: 8) {
                claimView(label: "Claim A", color: .blue, claim: contradiction.claimA)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.6))
                claimView(label: "Claim B", color: .orange, claim: contradiction.claimB)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.04))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.red.opacity(0.12), lineWidth: 1)
        )
    }

    private func claimView(label: String, color: Color, claim: InvestigationFeatures.Contradiction.ClaimInstance) -> some View {
        let senderName = claim.sender.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet.whitespaces) ?? "?"
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 7, weight: .bold)).foregroundColor(color)
            Text(senderName).font(.system(size: 8, weight: .medium))
            Text("\"\(claim.snippet)\"").font(.system(size: 8)).italic().lineLimit(3)
            if let date = claim.date {
                Text(date, style: .date).font(.system(size: 7)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Anomaly Suggested Leads (v3)

    private var anomalySuggestedLeads: some View {
        let toneShifts = anomalies.filter { $0.type == .toneShift }
        let spikes = anomalies.filter { $0.type == .frequencySpike }
        let relevant = (toneShifts + spikes).sorted { $0.severity > $1.severity }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Anomaly-Suggested Leads", icon: "lightbulb.fill", color: .orange)
            Text("Tone shifts and frequency spikes may indicate newsworthy developments.")
                .font(.system(size: 10)).foregroundColor(.secondary)

            if relevant.isEmpty {
                Text("No anomaly-based leads found.").font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ForEach(relevant.prefix(6)) { anomaly in
                    HStack(spacing: 6) {
                        Image(systemName: anomaly.type.icon).font(.system(size: 10))
                            .foregroundColor(anomaly.severity > 0.7 ? .red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(anomaly.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Text(anomaly.detail).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            leads.append(Lead(title: anomaly.title, notes: "Auto-suggested from \(anomaly.type.rawValue): \(anomaly.detail)"))
                        } label: {
                            Image(systemName: "plus.circle").font(.system(size: 11)).foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Color.orange.opacity(0.04))
                    .cornerRadius(4)
                }
            }
        }
    }

    private func extractTopics() -> [(String, Int, [String])] {
        var wordFrequency: [String: Int] = [:]
        var wordSubjects: [String: [String]] = [:]
        let stopWords: Set<String> = ["re", "fwd", "fw", "the", "and", "for", "with", "from", "that", "this",
                                       "have", "been", "will", "are", "was", "not", "but", "all", "can",
                                       "had", "her", "one", "our", "out", "you", "your", "has", "its"]

        for email in effectiveEmails {
            let subject = email.headers["Subject"] ?? ""
            let cleaned = subject.lowercased()
                .replacingOccurrences(of: "re:", with: "")
                .replacingOccurrences(of: "fwd:", with: "")
                .replacingOccurrences(of: "fw:", with: "")
                .trimmingCharacters(in: .whitespaces)

            let words = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stopWords.contains($0) }

            for word in Set(words) {
                wordFrequency[word, default: 0] += 1
                wordSubjects[word, default: []].append(subject)
            }
        }

        return wordFrequency
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(25)
            .map { ($0.key.capitalized, $0.value, wordSubjects[$0.key] ?? []) }
    }

    // MARK: - Leads View

    private var leadsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Investigation Leads", icon: "lightbulb", color: .purple)

                HStack(spacing: 8) {
                    TextField("Lead title...", text: $newLeadTitle)
                        .font(.system(size: 11))
                        .textFieldStyle(.roundedBorder)
                    TextField("Notes...", text: $newLeadNotes)
                        .font(.system(size: 11))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if !newLeadTitle.isEmpty {
                            leads.append(Lead(title: newLeadTitle, notes: newLeadNotes))
                            newLeadTitle = ""
                            newLeadNotes = ""
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundColor(.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(newLeadTitle.isEmpty)
                }
                .padding(8)
                .background(AppColors.backgroundSecondary.opacity(0.3))
                .cornerRadius(6)

                if leads.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "lightbulb").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.3))
                        Text("No leads yet. Use the field above to type a lead, or check the Auto-Detected Leads section for AI-suggested starting points.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(leads) { lead in
                        leadCard(lead)
                    }
                }

                if hasInvestigationFeatures && !storyLeads.isEmpty {
                    Divider()
                    storyLeadsSection
                }
            }
            .padding(12)
        }
    }

    // MARK: - Story Leads (InvestigationFeatures)

    private var storyLeadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Auto-Detected Story Leads", icon: "sparkle.magnifyingglass", color: .cyan)
            Text("Auto-detected leads based on pattern breaks, emerging topics, conflicts, and unusual connections.")
                .font(.system(size: 9)).foregroundColor(.secondary)

            ForEach(Array(storyLeads.prefix(10))) { lead in
                storyLeadCard(lead)
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.03))
        .cornerRadius(8)
    }

    private func storyLeadCard(_ storyLead: InvestigationFeatures.StoryLead) -> some View {
        let color = storyLeadColor(storyLead.leadType)
        let scoreText = String(format: "%.0f%%", storyLead.relevanceScore * 100)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(storyLead.leadType.rawValue)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(color))
                Text(scoreText)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .help("Investigation relevance based on emerging topics, pattern breaks, and anomaly correlations")
                Spacer()
                Button {
                    leads.append(Lead(title: storyLead.headline, notes: storyLead.suggestedAngle))
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus.circle").font(.system(size: 9))
                        Text("Add Lead").font(.system(size: 8))
                    }
                    .foregroundColor(.purple)
                }
                .buttonStyle(.plain)
            }

            Text(storyLead.headline)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)

            Text("Angle: \(storyLead.suggestedAngle)")
                .font(.system(size: 9)).italic()
                .foregroundColor(.secondary)
                .lineLimit(2)

            if !storyLead.keyEntities.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person.text.rectangle").font(.system(size: 7)).foregroundColor(.secondary)
                    ForEach(Array(storyLead.keyEntities.prefix(4)), id: \.self) { entity in
                        Text(entity)
                            .font(.system(size: 7))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.1))
                            .cornerRadius(2)
                    }
                }
            }
        }
        .padding(8)
        .background(color.opacity(0.04))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.15), lineWidth: 1)
        )
    }

    private func storyLeadColor(_ type: InvestigationFeatures.StoryLead.LeadType) -> Color {
        switch type {
        case .patternBreak: return .orange
        case .emergingTopic: return .cyan
        case .conflictDetected: return .red
        case .insiderSignal: return .purple
        case .sentimentShift: return .yellow
        case .unusualConnection: return .indigo
        }
    }

    private func leadCard(_ lead: Lead) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(lead.priority.color).frame(width: 8, height: 8)
                Text(lead.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu(lead.priority.rawValue) {
                    ForEach(Lead.Priority.allCases, id: \.self) { priority in
                        Button(priority.rawValue) {
                            if let idx = leads.firstIndex(where: { $0.id == lead.id }) {
                                leads[idx].priority = priority
                            }
                        }
                    }
                }
                .font(.system(size: 9))

                Button {
                    leads.removeAll { $0.id == lead.id }
                } label: {
                    Image(systemName: "trash").font(.system(size: 9)).foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            if !lead.notes.isEmpty {
                Text(lead.notes).font(.system(size: 10)).foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 8))
                Text(lead.created, style: .relative).font(.system(size: 8))
                if !lead.linkedEmailIDs.isEmpty {
                    Text("\(lead.linkedEmailIDs.count) linked emails").font(.system(size: 8))
                }
            }
            .foregroundColor(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(lead.priority.color.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(lead.priority.color.opacity(0.15), lineWidth: 1))
        )
    }

    // MARK: - Quotes View

    private var quotesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Key Quotes", icon: "quote.opening", color: .purple)
                Text("Extract and save important quotes from emails for your investigation.")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                if keyQuotes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "quote.opening").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.3))
                        Text("No quotes saved yet. Browse source emails and bookmark key quotes, or check Auto-Extracted Quotes for suggestions.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(keyQuotes) { quote in
                        quoteCard(quote)
                    }
                }

                if !aiQuotes.isEmpty {
                    Divider()
                    sectionTitle("AI-Extracted Quotes", icon: "sparkles", color: .cyan)
                    ForEach(aiQuotes) { quote in
                        quoteCard(quote)
                    }
                } else {
                    Button("Extract Quotes with AI") { extractAIQuotes() }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.purple)
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    if isExtractingQuotes {
                        HStack { ProgressView().controlSize(.small); Text("Extracting...").font(.system(size: 9)) }
                    }
                }

                if hasInvestigationFeatures && !extractedQuotesNLP.isEmpty {
                    Divider()
                    nlpQuotesSection
                }

                Divider()
                sectionTitle("Suggested Quotes", icon: "text.quote", color: .purple)
                Text("Sentences containing actionable language or key findings.")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                let suggestions = findSuggestedQuotes()
                ForEach(suggestions, id: \.text) { suggestion in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\"\(suggestion.text)\"")
                                .font(.system(size: 10))
                                .italic()
                            Text("— \(suggestion.from), \(suggestion.date)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            keyQuotes.append(suggestion)
                        } label: {
                            Image(systemName: "plus.circle").font(.system(size: 12)).foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(AppColors.backgroundSecondary.opacity(0.2))
                    .cornerRadius(4)
                }
            }
            .padding(12)
        }
    }

    private func quoteCard(_ quote: KeyQuote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\"\(quote.text)\"")
                .font(.system(size: 11))
                .italic()
            HStack {
                Text("— \(quote.from)").font(.system(size: 9, weight: .medium))
                Text(quote.date).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                if !quote.tag.isEmpty {
                    Text(quote.tag)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.purple))
                }
                Button {
                    keyQuotes.removeAll { $0.id == quote.id }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.purple.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.purple.opacity(0.15), lineWidth: 1))
        )
    }

    // MARK: - NLP Extracted Quotes (InvestigationFeatures)

    private var nlpQuotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Auto-Extracted Quotes", icon: "text.magnifyingglass", color: .mint, tip: "Quotes automatically found in emails — ranked by how newsworthy they are based on impact, specificity, and actionable language")
            Text("Notable quotes detected in emails, ranked by potential newsworthiness.")
                .font(.system(size: 9)).foregroundColor(.secondary)

            ForEach(Array(extractedQuotesNLP.prefix(12))) { quote in
                nlpQuoteCard(quote)
            }
        }
        .padding(10)
        .background(Color.mint.opacity(0.03))
        .cornerRadius(8)
    }

    private func nlpQuoteCard(_ quote: InvestigationFeatures.ExtractedQuote) -> some View {
        let scoreText = String(format: "%.0f%%", quote.newsworthiness * 100)
        let scoreColor: Color = quote.newsworthiness > 0.6 ? .red : quote.newsworthiness > 0.4 ? .orange : .secondary
        return VStack(alignment: .leading, spacing: 4) {
            Text("\"\(quote.text)\"")
                .font(.system(size: 10))
                .italic()
                .lineLimit(3)
            HStack(spacing: 6) {
                Text("-- \(quote.speaker)")
                    .font(.system(size: 9, weight: .medium))
                if !quote.context.isEmpty {
                    Text("re: \(quote.context)")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 2) {
                    Image(systemName: "newspaper").font(.system(size: 7))
                    Text(scoreText).font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundColor(scoreColor)
                .help("Newsworthiness score based on impact words, specific claims, and actionable language")
                Button {
                    keyQuotes.append(KeyQuote(
                        text: quote.text,
                        emailID: quote.email.id,
                        from: quote.speaker,
                        date: quote.context,
                        tag: "NLP"
                    ))
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 10)).foregroundColor(.purple)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.mint.opacity(0.04))
        .cornerRadius(5)
    }

    private func findSuggestedQuotes() -> [KeyQuote] {
        let actionTerms = ["confirm", "agreed", "decided", "approved", "rejected", "denied",
                           "promise", "guarantee", "deadline", "urgent", "critical",
                           "meeting", "discussed", "consensus", "authorized"]
        var quotes: [KeyQuote] = []

        for email in effectiveEmails.prefix(100) {
            let sentences = email.plainBody.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            let from = email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?"
            let date = email.headers["Date"] ?? ""

            for sentence in sentences {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                guard trimmed.count > 20 && trimmed.count < 300 else { continue }
                if actionTerms.contains(where: { lower.contains($0) }) {
                    quotes.append(KeyQuote(text: trimmed, emailID: email.id, from: from, date: date))
                    if quotes.count >= 10 { return quotes }
                }
            }
        }
        return quotes
    }

    // MARK: - Overview View

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Investigation Overview", icon: "chart.bar", color: .purple)

                let contacts = computeContactStats()
                let dateRange = computeDateRange()

                HStack(spacing: 12) {
                    overviewCard("Total Emails", value: "\(effectiveEmails.count)", icon: "envelope", color: .blue)
                    overviewCard("Unique Contacts", value: "\(contacts.count)", icon: "person.3", color: .purple)
                    overviewCard("Bookmarked", value: "\(bookmarkedEmailIDs.count)", icon: "bookmark.fill", color: .orange)
                    overviewCard("Leads", value: "\(leads.count)", icon: "lightbulb", color: .yellow)
                }

                HStack(spacing: 12) {
                    overviewCard("Key Quotes", value: "\(keyQuotes.count)", icon: "quote.opening", color: .teal)
                    overviewCard("Attachments", value: "\(effectiveEmails.flatMap { $0.attachments }.count)", icon: "paperclip", color: .brown)
                    overviewCard("Date Range", value: dateRange, icon: "calendar", color: .green)
                    overviewCard("Avg/Day", value: computeAvgPerDay(), icon: "chart.line.uptrend.xyaxis", color: .cyan)
                }

                Divider()

                sectionTitle("Top 10 Sources", icon: "person.3", color: .purple)
                ForEach(Array(contacts.prefix(10).enumerated()), id: \.element.email) { index, contact in
                    HStack {
                        Text("\(index + 1).").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.secondary).frame(width: 20)
                        Text(contact.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(contact.totalCount) emails")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.purple)
                    }
                }

                if hasSentimentAnalysis {
                    Divider()
                    sentimentOverview
                }

                Divider()

                aiInvestigationBriefSection
                Divider()

                if !digestSections.isEmpty { investigationDigestSection; Divider() }

                if hasInvestigationFeatures {
                    investigationFeaturesOverview
                    Divider()
                }

                sectionTitle("Investigation Checklist", icon: "checklist", color: .green)
                investigationChecklist
            }
            .padding(12)
        }
    }

    private func overviewCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(color.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - AI Investigation Brief (v4)

    private var aiInvestigationBriefSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.purple)
                Text("AI Investigation Brief").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isGeneratingNarrative {
                    ProgressView().controlSize(.small)
                } else if aiNarrative.isEmpty {
                    Button("Generate") { generateAINarrative() }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.purple)
                        .buttonStyle(.plain)
                }
            }
            if !aiNarrative.isEmpty {
                Text(aiNarrative)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
            } else if !isGeneratingNarrative {
                Text("Generate an AI-powered analysis of your investigation emails.")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Investigation Digest (v4)

    private var investigationDigestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Investigation Digest", icon: "doc.text.magnifyingglass", color: .teal)
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
    }

    // MARK: - Investigation Features Overview

    private var investigationFeaturesOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Deep Analysis Summary", icon: "brain.head.profile", color: .indigo)

            HStack(spacing: 12) {
                overviewCard("Credible Sources", value: "\(sourceCredibilities.filter { $0.overallScore >= 0.6 }.count)", icon: "checkmark.seal.fill", color: .green)
                overviewCard("Story Leads", value: "\(storyLeads.count)", icon: "sparkle.magnifyingglass", color: .cyan)
                overviewCard("Contradictions", value: "\(contradictions.count)", icon: "arrow.left.arrow.right", color: .red)
                overviewCard("Auto Quotes", value: "\(extractedQuotesNLP.count)", icon: "text.magnifyingglass", color: .mint)
            }

            HStack(spacing: 12) {
                overviewCard("Timeline Events", value: "\(timelineEvents.count)", icon: "flag.fill", color: .teal)
                overviewCard("Avg Credibility", value: sourceCredibilities.isEmpty ? "N/A" : String(format: "%.0f%%", sourceCredibilities.map(\.overallScore).reduce(0, +) / Double(sourceCredibilities.count) * 100), icon: "gauge.medium", color: .indigo)
                overviewCard("Top Lead", value: storyLeads.first.map { String(format: "%.0f%%", $0.relevanceScore * 100) } ?? "N/A", icon: "lightbulb.fill", color: .orange)
                overviewCard("Event Types", value: "\(Set(timelineEvents.map(\.eventType)).count)", icon: "list.bullet.rectangle", color: .purple)
            }
        }
    }

    // MARK: - PDF Export Sheet (v4)

    private var pdfExportSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Export Investigation Report").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Generate PDF") {
                    Task {
                        let bookmarked = effectiveEmails.filter { bookmarkedEmailIDs.contains($0.id) }
                        let target = bookmarked.isEmpty ? emails : bookmarked
                        let data = await InvestigationReportGenerator.generateReport(
                            emails: target,
                            title: "Investigation Report",
                            investigatorName: "Journalist"
                        )
                        #if os(macOS)
                        _ = PlatformFileSaver.saveData(data, suggestedName: "investigation_report.pdf")
                        #endif
                    }
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                Button("Done") { showPDFExport = false }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("This report will include:")
                    .font(.system(size: 12, weight: .medium))
                let bookmarked = bookmarkedEmailIDs.count
                Text("• \(bookmarked > 0 ? "\(bookmarked) bookmarked" : "\(effectiveEmails.count) total") emails")
                Text("• \(leads.count) investigation leads")
                Text("• \(keyQuotes.count) key quotes")
                Text("• AI-enhanced analysis (if available)")
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 350)
    }

    private var investigationChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            checklistItem("Identify key sources", done: !computeContactStats().isEmpty)
            checklistItem("Review timeline for gaps", done: false)
            checklistItem("Extract key quotes", done: !keyQuotes.isEmpty)
            checklistItem("Document leads", done: !leads.isEmpty)
            checklistItem("Cross-reference sources", done: hasInvestigationFeatures && !sourceCredibilities.isEmpty)
            checklistItem("Verify claims against evidence", done: hasInvestigationFeatures && !contradictions.isEmpty)
            checklistItem("Redact sensitive information", done: false)
            checklistItem("Export investigation notes", done: false)
        }
    }

    private func checklistItem(_ text: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundColor(done ? .green : .secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(done ? .secondary : .primary)
                .strikethrough(done)
        }
    }

    // MARK: - Export Notes Sheet

    private var exportNotesSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Export Investigation Notes").font(.title3).fontWeight(.bold)
                Spacer()
                Button("Export") { performExport() }
                    .buttonStyle(.borderedProminent).tint(.purple)
                Button("Done") { showExportNotes = false }
            }

            ScrollView {
                Text(generateExportText())
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
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

    private func emailSnippet(_ email: MBOXParser.RawEmail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text(email.headers["Date"] ?? "").font(.system(size: 9)).foregroundColor(.secondary)
            }
            Text(email.headers["Subject"] ?? "(No Subject)")
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            Text(String(email.plainBody.prefix(200)))
                .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7)).lineLimit(2)
        }
        .padding(6)
        .background(AppColors.backgroundSecondary.opacity(0.2))
        .cornerRadius(4)
    }

    private func extractEmail(_ raw: String) -> String {
        if let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">") {
            return String(raw[raw.index(after: start)..<end])
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private func formatShortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yy"
        return f.string(from: date)
    }

    private func computeDateRange() -> String {
        let dates = effectiveEmails.compactMap { MBOXParser.parseDate($0.headers["Date"] ?? "") }
        guard let first = dates.min(), let last = dates.max() else { return "N/A" }
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return "\(f.string(from: first)) — \(f.string(from: last))"
    }

    private func computeAvgPerDay() -> String {
        let dates = effectiveEmails.compactMap { MBOXParser.parseDate($0.headers["Date"] ?? "") }
        guard let first = dates.min(), let last = dates.max() else { return "N/A" }
        let days = max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 1)
        return String(format: "%.1f", Double(effectiveEmails.count) / Double(days))
    }

    private func generateExportText() -> String {
        var text = "INVESTIGATION NOTES\n"
        text += String(repeating: "=", count: 60) + "\n"
        text += "Date: \(Date())\n"
        text += "Total Emails: \(effectiveEmails.count)\n"
        text += "Contacts: \(computeContactStats().count)\n\n"

        if !leads.isEmpty {
            text += "LEADS\n"
            text += String(repeating: "-", count: 40) + "\n"
            for lead in leads {
                text += "[\(lead.priority.rawValue)] \(lead.title)\n"
                if !lead.notes.isEmpty { text += "  Notes: \(lead.notes)\n" }
            }
            text += "\n"
        }

        if !keyQuotes.isEmpty {
            text += "KEY QUOTES\n"
            text += String(repeating: "-", count: 40) + "\n"
            for quote in keyQuotes {
                text += "\"\(quote.text)\"\n  — \(quote.from), \(quote.date)\n\n"
            }
        }

        if !bookmarkedEmailIDs.isEmpty {
            text += "BOOKMARKED EMAILS (\(bookmarkedEmailIDs.count))\n"
            text += String(repeating: "-", count: 40) + "\n"
            for email in effectiveEmails where bookmarkedEmailIDs.contains(email.id) {
                text += "  Subject: \(email.headers["Subject"] ?? "(No Subject)")\n"
                text += "  From: \(email.headers["From"] ?? "")\n"
                text += "  Date: \(email.headers["Date"] ?? "")\n\n"
            }
        }

        return text
    }

    // MARK: - Sentiment Analysis

    private var sentimentOverview: some View {
        let positive = sentimentCache.values.filter { $0.score > 0.2 }.count
        let negative = sentimentCache.values.filter { $0.score < -0.2 }.count
        let neutral = sentimentCache.values.filter { $0.score >= -0.2 && $0.score <= 0.2 }.count

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Sentiment Analysis", icon: "face.smiling", color: .purple)
            HStack(spacing: 12) {
                overviewCard("Positive", value: "\(positive)", icon: "face.smiling", color: .green)
                overviewCard("Neutral", value: "\(neutral)", icon: "minus.circle", color: .gray)
                overviewCard("Negative", value: "\(negative)", icon: "exclamationmark.triangle", color: .red)
                overviewCard("Avg Score", value: String(format: "%.2f", sentimentCache.values.map(\.score).reduce(0, +) / max(1, Double(sentimentCache.count))), icon: "chart.bar", color: .purple)
            }
        }
    }

    private func runSentimentAnalysis() {
        let emailsCopy = effectiveEmails
        Task.detached(priority: .userInitiated) {
            var results: [UUID: SentimentResult] = [:]
            let positiveWords: Set<String> = ["thank", "thanks", "great", "good", "excellent", "wonderful", "appreciate",
                                               "happy", "pleased", "agree", "love", "perfect", "best", "awesome"]
            let negativeWords: Set<String> = ["urgent", "problem", "issue", "fail", "error", "wrong", "bad",
                                               "terrible", "complaint", "angry", "frustrated", "disappointed",
                                               "deadline", "overdue", "critical", "concern"]

            for email in emailsCopy {
                let words = email.plainBody.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
                let total = max(1, Double(words.count))
                let pos = Double(words.filter { positiveWords.contains($0) }.count) / total * 100
                let neg = Double(words.filter { negativeWords.contains($0) }.count) / total * 100
                let score = min(1, max(-1, (pos - neg) / max(1, pos + neg)))
                let label = score > 0.2 ? "Positive" : score < -0.2 ? "Negative" : "Neutral"
                results[email.id] = SentimentResult(score: score, label: label)
            }

            let finalResults = results
            await MainActor.run {
                sentimentCache = finalResults
                hasSentimentAnalysis = true
            }
        }
    }

    private struct CredibilityInfo {
        var label: String
        var icon: String
        var color: Color
    }

    private func sourceCredibility(_ contact: ContactStat) -> CredibilityInfo {
        var score = 0.0
        if contact.totalCount >= 10 { score += 3 }
        else if contact.totalCount >= 5 { score += 2 }
        else { score += 1 }

        if let first = contact.firstSeen, let last = contact.lastSeen {
            let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
            if days > 90 { score += 2 }
            else if days > 30 { score += 1 }
        }

        if contact.sentCount > 0 && contact.receivedCount > 0 { score += 1 }

        if hasV3Analysis {
            if let insight = contactInsights.first(where: { $0.address.lowercased().contains(contact.email.lowercased()) }) {
                if insight.avgSentiment > 0.2 { score += 1 }
            }
            if kgLoaded {
                let personID = "person:\(contact.email)"
                let kgNeighbors = graph.neighbors(of: personID, type: .discussesTopic)
                if kgNeighbors.count >= 3 { score += 1 }
            }
        }

        if score >= 6 {
            return CredibilityInfo(label: "High", icon: "checkmark.seal.fill", color: .green)
        } else if score >= 3 {
            return CredibilityInfo(label: "Med", icon: "checkmark.seal", color: .orange)
        }
        return CredibilityInfo(label: "Low", icon: "questionmark.circle", color: .red)
    }

    private func performExport() {
        let text = generateExportText()
        #if os(macOS)
        _ = PlatformFileSaver.saveText(text, suggestedName: "investigation_notes.txt")
        #endif
    }
}
