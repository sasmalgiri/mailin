import SwiftUI

struct GeneralAnalysisView: View {
    let emails: [MBOXParser.RawEmail]
    let onNavigate: (HubDestination) -> Void

    // MARK: - State

    @State private var searchText = ""
    @State private var showTips = true
    @State private var showSearchResults = false
    @State private var recentFeatures: [HubDestination] = []

    // v3: KG + NLP + Anomaly
    @State private var graph = KnowledgeGraph()
    @State private var kgLoaded = false
    @State private var sentimentResults: [EmailNLPEngine.SentimentResult] = []
    @State private var anomalies: [AnomalyDetectionEngine.Anomaly] = []
    @State private var hasAnalyzed = false
    @State private var isAnalyzing = false

    // v4: AI + Background + Digest
    @State private var aiNarrative = ""
    @State private var isGeneratingAI = false
    @State private var digestSections: [AIDigestGenerator.DigestSection] = []
    @State private var isGeneratingDigest = false
    @ObservedObject private var backgroundManager = BackgroundAnalysisManager.shared

    // v5: Archive Insights
    @State private var trends: [ArchiveInsightsFeatures.TrendAnalysis] = []
    @State private var archiveComposition: ArchiveInsightsFeatures.ArchiveComposition?
    @State private var communicationPatterns: [ArchiveInsightsFeatures.CommunicationPattern] = []
    @StateObject private var coordinator = AnalysisCoordinator()
    @State private var showTutorial = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroSection
                if !aiNarrative.isEmpty { aiNarrativeSection; Divider() }
                if !backgroundManager.lastRunFindings.isEmpty { proactiveInsightsCard; Divider() }
                if !digestSections.isEmpty { digestPreviewCard; Divider() }
                quickSearchBar
                quickStatsRow
                if kgLoaded { kgInsightsSection; Divider() }
                archiveHealthSection
                if !trends.isEmpty { Divider(); trendsSection }
                if archiveComposition != nil { Divider(); compositionSection }
                if !communicationPatterns.isEmpty { Divider(); communicationPatternsSection }
                Divider()
                gettingStartedSection
                Divider()
                if !recentFeatures.isEmpty { recentlyUsedSection; Divider() }
                featuredSection
                Divider()
                featureDiscovery
                Divider()
                if showTips { tipsSection }
                privacyNote
            }
            .padding(16)
        }
        .overlay { if AnalysisCoordinator.isEnabled { AnalysisProgressOverlay(coordinator: coordinator) } }
        .featureTutorial(.general, key: "general_tutorial_seen", isPresented: $showTutorial)
        .task { await loadV3Data() }
        .task { await loadV4Data() }
    }

    private func loadV3Data() async {
        let loaded = KnowledgeGraph.load()
        if loaded.nodeCount > 0 { graph = loaded; kgLoaded = true }

        guard !hasAnalyzed else { return }
        isAnalyzing = true
        let emailsCopy = emails
        let graphForPatterns: KnowledgeGraph? = kgLoaded ? graph : nil

        guard AnalysisCoordinator.isEnabled else {
            sentimentResults = EmailNLPEngine.analyzeSentiment(of: emailsCopy)
            anomalies = AnomalyDetectionEngine.detectAnomalies(in: emailsCopy)
            hasAnalyzed = true; isAnalyzing = false
            trends = ArchiveInsightsFeatures.detectTrends(in: emailsCopy)
            archiveComposition = ArchiveInsightsFeatures.analyzeComposition(emails: emailsCopy)
            communicationPatterns = ArchiveInsightsFeatures.analyzeCommunicationPatterns(emails: emailsCopy, graph: graphForPatterns)
            return
        }

        coordinator.begin(steps: 5, color: .mint)

        coordinator.advance(step: 1, label: "Analyzing sentiment...")
        guard let sentiment = await coordinator.runDetached({ EmailNLPEngine.analyzeSentiment(of: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 2, label: "Detecting anomalies...")
        guard let anomalyResults = await coordinator.runDetached({ AnomalyDetectionEngine.detectAnomalies(in: emailsCopy) }) else { coordinator.finish(); return }

        sentimentResults = sentiment; anomalies = anomalyResults
        hasAnalyzed = true; isAnalyzing = false

        coordinator.advance(step: 3, label: "Detecting trends...")
        guard let trendResults = await coordinator.runDetached({ ArchiveInsightsFeatures.detectTrends(in: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 4, label: "Analyzing archive composition...")
        guard let composition = await coordinator.runDetached({ ArchiveInsightsFeatures.analyzeComposition(emails: emailsCopy) }) else { coordinator.finish(); return }

        coordinator.advance(step: 5, label: "Mapping communication patterns...")
        guard let patterns = await coordinator.runDetached({ ArchiveInsightsFeatures.analyzeCommunicationPatterns(emails: emailsCopy, graph: graphForPatterns) }) else { coordinator.finish(); return }

        trends = trendResults; archiveComposition = composition; communicationPatterns = patterns
        coordinator.finish()
    }

    private func loadV4Data() async {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard !isGeneratingAI && aiNarrative.isEmpty else { return }
            isGeneratingAI = true
            let result = try? await FoundationModelEngine.summarize(emails: emails)
            aiNarrative = result ?? ""
            isGeneratingAI = false
        }
        #endif

        if digestSections.isEmpty {
            isGeneratingDigest = true
            let sections = await AIDigestGenerator.generateDigest(emails: emails, period: .today)
            digestSections = sections
            isGeneratingDigest = false
        }
    }

    // MARK: - AI Narrative (v4)

    private var aiNarrativeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundColor(.purple)
                Text("AI Archive Summary").font(.system(size: 13, weight: .semibold))
                Spacer()
                if isGeneratingAI {
                    ProgressView().controlSize(.small)
                }
            }
            Text(aiNarrative)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color.purple.opacity(0.06), Color.purple.opacity(0.02)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    // MARK: - Proactive Insights (v4)

    private var proactiveInsightsCard: some View {
        let topFindings = backgroundManager.lastRunFindings
            .sorted { $0.severity > $1.severity }
            .prefix(5)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge").font(.system(size: 12)).foregroundColor(.orange)
                Text("What's New").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let date = backgroundManager.lastRunDate {
                    Text(date, style: .relative)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }

            ForEach(Array(topFindings)) { finding in
                HStack(spacing: 6) {
                    Circle()
                        .fill(finding.severity >= 0.7 ? Color.red : finding.severity >= 0.4 ? .orange : .green)
                        .frame(width: 6, height: 6)
                    Text(finding.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(finding.category).font(.system(size: 8)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Digest Preview (v4)

    private var digestPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12)).foregroundColor(.teal)
                Text("Today's Digest").font(.system(size: 13, weight: .semibold))
                Spacer()
                if isGeneratingDigest {
                    ProgressView().controlSize(.small)
                }
            }

            if digestSections.isEmpty && !isGeneratingDigest {
                Text("No digest items for today — check back after importing new emails.").font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ForEach(digestSections.prefix(3)) { section in
                    VStack(alignment: .leading, spacing: 3) {
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
        .padding(12)
        .background(Color.teal.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - KG Insights (v3)

    private var kgInsightsSection: some View {
        let stats = graph.statistics()
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Relationship Map", icon: "point.3.connected.trianglepath.dotted", color: .cyan, tip: "A map of all the people, organizations, and topics found in your emails and how they connect to each other")

            HStack(spacing: 10) {
                statPill("People", value: "\(stats.people)", color: .blue)
                statPill("Organizations", value: "\(stats.orgs)", color: .orange)
                statPill("Topics", value: "\(stats.topics)", color: .teal)
                statPill("Connections", value: "\(stats.edges)", color: .purple)
            }

            let topPeople = graph.topNodes(by: .person, limit: 5)
            let topTopics = graph.topNodes(by: .topic, limit: 5)

            if !topPeople.isEmpty {
                Text("Top Contacts").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(topPeople, id: \.id) { node in
                        kgChip(node.label, color: .blue)
                    }
                }
            }

            if !topTopics.isEmpty {
                Text("Key Topics").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(topTopics, id: \.id) { node in
                        kgChip(node.label, color: .teal)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(10)
    }

    private func kgChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .cornerRadius(12)
    }

    // MARK: - Archive Health (v3)

    private var archiveHealthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Archive Health", icon: "heart.text.square", color: .pink, tip: "An overall quality score for your email archive — checks sentiment balance, anomaly levels, and data completeness")

            if isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing archive...").font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else if !hasAnalyzed {
                Text("Tap 'Run Analysis' to scan your emails for health metrics, sentiment, and anomalies.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                let avgSentiment = sentimentResults.isEmpty ? 0.0 : sentimentResults.reduce(0.0) { $0 + $1.score } / Double(sentimentResults.count)
                let positive = sentimentResults.filter { $0.score > 0.4 }.count
                let negative = sentimentResults.filter { $0.score < -0.4 }.count
                let neutral = sentimentResults.count - positive - negative
                let highAnomalies = anomalies.filter { $0.severity > 0.7 }.count
                let medAnomalies = anomalies.filter { $0.severity > 0.4 && $0.severity <= 0.7 }.count
                let lowAnomalies = anomalies.filter { $0.severity <= 0.4 }.count
                let healthScore = computeHealthScore(avgSentiment: avgSentiment, highAnomalies: highAnomalies, totalAnomalies: anomalies.count)

                HStack(spacing: 12) {
                    healthGauge(score: healthScore)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            healthMetric("Positive", value: "\(positive)", color: .green)
                            healthMetric("Neutral", value: "\(neutral)", color: .gray)
                            healthMetric("Negative", value: "\(negative)", color: .red)
                        }
                        HStack(spacing: 12) {
                            healthMetric("High Risk", value: "\(highAnomalies)", color: .red)
                            healthMetric("Medium", value: "\(medAnomalies)", color: .orange)
                            healthMetric("Low", value: "\(lowAnomalies)", color: .yellow)
                        }
                        Text("Avg sentiment: \(String(format: "%.2f", avgSentiment)) (-1 to +1)")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                            .help("Average emotional tone across all emails. Negative = concerning/frustrated, Neutral = factual/business, Positive = upbeat/collaborative")
                    }
                }
            }
        }
        .padding(12)
        .background(Color.pink.opacity(0.04))
        .cornerRadius(10)
    }

    private func healthGauge(score: Int) -> some View {
        let color: Color = score >= 80 ? .green : score >= 50 ? .orange : .red
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 6)
                    .frame(width: 56, height: 56)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            Text("Health").font(.system(size: 8)).foregroundColor(.secondary)
        }
        .help("Archive health: 80+ = Excellent (clean, well-threaded), 50-79 = Fair, below 50 = Needs attention (high anomalies or negative tone)")
    }

    private func healthMetric(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundColor(.primary)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    private func computeHealthScore(avgSentiment: Double, highAnomalies: Int, totalAnomalies: Int) -> Int {
        var score = 70.0
        score += avgSentiment * 15
        score -= Double(highAnomalies) * 8
        score -= Double(max(0, totalAnomalies - 3)) * 2
        return max(0, min(100, Int(score)))
    }

    // MARK: - Trends Section (v5)

    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Trends Over Time", icon: "chart.line.uptrend.xyaxis", color: .cyan, tip: "Shows how email volume, sentiment, and topics have changed over time — helps spot periods of unusual activity")

            ForEach(trends) { trend in
                HStack(spacing: 10) {
                    Image(systemName: trendDirectionIcon(trend.direction))
                        .font(.system(size: 16))
                        .foregroundColor(trendDirectionColor(trend.direction))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(trend.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", trend.magnitude * 100))
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(trendDirectionColor(trend.direction).opacity(0.8))
                                .cornerRadius(8)
                                .help("Rate of change compared to historical baseline")
                        }
                        Text(trend.detail)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .background(Color.cyan.opacity(0.03))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.cyan.opacity(0.04))
        .cornerRadius(10)
    }

    private func trendDirectionIcon(_ direction: ArchiveInsightsFeatures.TrendAnalysis.TrendDirection) -> String {
        switch direction {
        case .increasing: return "arrow.up.right"
        case .decreasing: return "arrow.down.right"
        case .stable: return "equal"
        case .volatile: return "waveform.path"
        }
    }

    private func trendDirectionColor(_ direction: ArchiveInsightsFeatures.TrendAnalysis.TrendDirection) -> Color {
        switch direction {
        case .increasing: return .green
        case .decreasing: return .red
        case .stable: return .blue
        case .volatile: return .orange
        }
    }

    // MARK: - Composition Section (v5)

    private var compositionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Archive Breakdown", icon: "chart.pie", color: .teal, tip: "A breakdown of your email archive — how many senders, domains, average email length, attachments, and conversation threads")

            if let comp = archiveComposition {
                HStack(spacing: 12) {
                    // Quality gauge
                    compositionGauge(score: comp.qualityScore)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            healthMetric("Senders", value: "\(comp.uniqueSenders)", color: .blue)
                                .help("Number of unique sender addresses in the archive")
                            healthMetric("Domains", value: "\(comp.uniqueDomains)", color: .green)
                                .help("Number of unique email domains (e.g., gmail.com, company.com)")
                            healthMetric("Avg Length", value: "\(comp.avgEmailLength)", color: .purple)
                                .help("Average character count per email body")
                        }
                        HStack(spacing: 12) {
                            healthMetric("Attachments", value: "\(Int(comp.attachmentRate * 100))%", color: .brown)
                                .help("\(Int(comp.attachmentRate * 100))% of emails have attachments")
                            healthMetric("Threaded", value: "\(Int(comp.threadRate * 100))%", color: .cyan)
                                .help("\(Int(comp.threadRate * 100))% of emails are part of a conversation thread")
                        }
                    }
                }

                // Quality factors
                if !comp.qualityFactors.isEmpty {
                    Text("Quality Factors").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    ForEach(comp.qualityFactors, id: \.name) { factor in
                        HStack(spacing: 6) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.teal.opacity(0.1))
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.teal)
                                        .frame(width: geo.size.width * CGFloat(factor.score), height: 4)
                                }
                            }
                            .frame(width: 50, height: 4)

                            Text(factor.name)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)

                            Spacer()

                            Text(factor.detail)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                // Category breakdown
                if !comp.categories.isEmpty {
                    Text("Categories").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(comp.categories.prefix(8), id: \.category) { cat in
                            Text("\(cat.category) (\(cat.count))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.teal)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.teal.opacity(0.1))
                                .cornerRadius(10)
                        }
                    }
                }

                // Language breakdown
                if !comp.languageBreakdown.isEmpty {
                    Text("Languages").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(comp.languageBreakdown.prefix(6), id: \.language) { lang in
                            Text("\(lang.language) \(Int(lang.percentage))%")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.indigo.opacity(0.08))
                                .cornerRadius(10)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.teal.opacity(0.04))
        .cornerRadius(10)
    }

    private func compositionGauge(score: Double) -> some View {
        let pct = Int(score * 100)
        let color: Color = pct >= 70 ? .green : pct >= 40 ? .orange : .red
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 6)
                    .frame(width: 56, height: 56)
                Circle()
                    .trim(from: 0, to: CGFloat(score))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))
                Text("\(pct)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            Text("Quality").font(.system(size: 8)).foregroundColor(.secondary)
        }
        .help("Archive quality score: considers diversity of senders, threading rate, attachment presence, and content length balance")
    }

    // MARK: - Communication Patterns Section (v5)

    private var communicationPatternsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Communication Patterns", icon: "person.3.sequence", color: .pink, tip: "Recurring patterns in how people communicate — who emails whom most, busiest times, and notable clusters of activity")

            ForEach(communicationPatterns.prefix(8)) { pattern in
                HStack(spacing: 10) {
                    Image(systemName: patternTypeIcon(pattern.patternType))
                        .font(.system(size: 14))
                        .foregroundColor(.pink)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(pattern.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)

                        Text(pattern.detail)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            // Significance bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.pink.opacity(0.1))
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.pink)
                                        .frame(width: geo.size.width * CGFloat(pattern.significance), height: 4)
                                }
                            }
                            .frame(width: 60, height: 4)

                            Text(String(format: "%.0f%%", pattern.significance * 100))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.pink)
                                .help("Pattern significance: how strongly this communication pattern stands out relative to overall email activity")

                            if !pattern.participants.isEmpty {
                                Spacer()
                                Text(pattern.participants.prefix(2).joined(separator: ", "))
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.pink.opacity(0.03))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.pink.opacity(0.04))
        .cornerRadius(10)
    }

    private func patternTypeIcon(_ type: ArchiveInsightsFeatures.CommunicationPattern.PatternType) -> String {
        switch type {
        case .cluster: return "circle.grid.3x3"
        case .hub: return "star.circle"
        case .bridge: return "arrow.triangle.branch"
        case .isolate: return "person.crop.circle.badge.minus"
        case .burst: return "bolt.fill"
        case .routine: return "repeat"
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(colors: [.mint, .mint.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: "sparkles")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to mailin")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Your \(emails.count) emails are ready to explore. Everything runs on-device.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            TutorialHelpButton(showTutorial: $showTutorial)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(colors: [Color.mint.opacity(0.08), Color.mint.opacity(0.02)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
    }

    // MARK: - Quick Search

    private var quickSearchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search your emails...", text: $searchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .onSubmit { showSearchResults = !searchText.isEmpty }
                if !searchText.isEmpty {
                    Button {
                        onNavigate(.emailInbox)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right.circle.fill").font(.system(size: 10))
                            Text("Search in Inbox").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Button { searchText = ""; showSearchResults = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(AppColors.backgroundSecondary.opacity(0.5))
            .cornerRadius(8)

            if showSearchResults && !searchText.isEmpty {
                searchResultsPreview
            }
        }
    }

    private var searchResultsPreview: some View {
        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        let results = EmailSearchIndex.shared.hybridSearch(query: searchText, terms: terms, limit: 10)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(results.count) results for \"\(searchText)\"")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.blue)
                Spacer()
                Button { onNavigate(.emailInbox) } label: {
                    Text("View All →").font(.system(size: 9, weight: .medium)).foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.top, 6)

            ForEach(Array(results.prefix(5).enumerated()), id: \.element.email.id) { _, result in
                HStack(spacing: 6) {
                    Image(systemName: "envelope").font(.system(size: 9)).foregroundColor(.secondary)
                    Text(result.email.headers["From"]?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? "?")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Text(result.email.headers["Subject"] ?? "").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", result.score * 100))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.blue.opacity(0.7))
                        .help("Search relevance: keyword matches, synonym expansion, and subject line proximity combined")
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
            }
        }
        .padding(.bottom, 6)
        .background(AppColors.backgroundSecondary.opacity(0.3))
        .cornerRadius(0).cornerRadius(8, antialiased: true)
    }

    // MARK: - Quick Stats

    private var quickStatsRow: some View {
        let contacts = Set(emails.compactMap { extractDomain(from: $0.headers["From"] ?? "") }).count
        let attachments = emails.flatMap { $0.attachments }.count
        let dateRange = computeDateRange()

        return HStack(spacing: 10) {
            statPill("Emails", value: "\(emails.count)", color: .blue)
            statPill("Domains", value: "\(contacts)", color: .green)
            statPill("Attachments", value: "\(attachments)", color: .brown)
            statPill("Range", value: dateRange, color: .purple)
        }
    }

    private func statPill(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(title).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(color.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - Featured Section

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Start Here", icon: "star.fill", color: .orange)
            Text("The most popular features to begin your analysis.")
                .font(.system(size: 10)).foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                featuredCard("AI Assistant", subtitle: "Ask questions about your emails",
                             icon: "sparkles", color: .purple, destination: .aiAssistant)
                featuredCard("Email Analytics", subtitle: "Charts, stats, and insights",
                             icon: "chart.bar", color: .blue, destination: .emailAnalytics)
                featuredCard("Topic Clusters", subtitle: "Auto-group by theme",
                             icon: "circle.grid.3x3", color: .teal, destination: .topicClusters)
                featuredCard("Timeline", subtitle: "See emails chronologically",
                             icon: "calendar.day.timeline.left", color: .purple, destination: .timeline)
                featuredCard("Relationships", subtitle: "Who contacts who",
                             icon: "point.3.connected.trianglepath.dotted", color: .mint, destination: .relationshipGraph)
                featuredCard("Executive Dashboard", subtitle: "High-level KPIs",
                             icon: "gauge.with.dots.needle.33percent", color: .blue, destination: .executiveDashboard)
            }
        }
    }

    private func featuredCard(_ title: String, subtitle: String, icon: String,
                              color: Color, destination: HubDestination) -> some View {
        Button {
            trackFeature(destination)
            onNavigate(destination)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature Discovery

    private var featureDiscovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("All Features", icon: "square.grid.2x2", color: .blue)

            featureGroup("Search & Browse", icon: "magnifyingglass", color: .blue, features: [
                (.emailInbox, "Email Inbox", "Full inbox with search and filters"),
                (.threadSummarizer, "Thread Summarizer", "AI-powered conversation summaries"),
                (.duplicateManager, "Duplicate Manager", "Find and manage duplicates"),
                (.attachmentGallery, "Attachment Gallery", "Browse all files and photos"),
            ])

            featureGroup("Analytics & Insights", icon: "chart.bar", color: .green, features: [
                (.emailAnalytics, "Email Analytics", "Comprehensive stats and charts"),
                (.topicClusters, "Topic Clusters", "NLP-based grouping by theme"),
                (.timeline, "Timeline", "Chronological email view"),
                (.communicationPatterns, "Communication Patterns", "Who communicates with whom"),
                (.relationshipGraph, "Relationship Graph", "Interactive network map"),
                (.executiveDashboard, "Executive Dashboard", "KPI overview and metrics"),
            ])

            featureGroup("Security & Compliance", icon: "shield", color: .red, features: [
                (.anomalyDetection, "Anomaly Detection", "Statistical outlier analysis"),
                (.iocExtractor, "IOC Extractor", "Threat indicator extraction"),
                (.smartAlerts, "Smart Alerts", "Pattern monitoring and alerts"),
                (.keywordMonitor, "Keyword Monitor", "Track specific terms"),
                (.gdprCompliance, "GDPR Compliance", "Data protection reports"),
            ])

            featureGroup("Export & Reports", icon: "doc.text", color: .orange, features: [
                (.reportBuilder, "Report Builder", "Generate PDF reports"),
                (.batchOperations, "Batch Operations", "Bulk actions on emails"),
                (.archiveComparison, "Archive Compare", "Diff two email archives"),
                (.redaction, "Redaction", "Remove sensitive content"),
            ])

            featureGroup("AI & Intelligence", icon: "sparkles", color: .purple, features: [
                (.aiAssistant, "AI Assistant", "Natural language email Q&A"),
                (.aiDigest, "AI Digest", "Smart archive summary"),
                (.smartAutoTagger, "Smart Auto-Tagger", "NLP email classification"),
                (.customExperts, "Custom Experts", "Configure AI specialists"),
            ])

            featureGroup("Advanced", icon: "gearshape.2", color: .gray, features: [
                (.forensicReview, "Forensic Review", "Evidence coding workspace"),
                (.eDiscovery, "eDiscovery", "EDRM workflow"),
                (.predictiveCoding, "Predictive Coding", "TAR classifier"),
                (.batesNumbering, "Bates Numbering", "Document stamping"),
                (.chainOfCustody, "Chain of Custody", "Evidence tracking"),
                (.nearDuplicates, "Near Duplicates", "Similarity detection"),
                (.automationRules, "Automation Rules", "Custom workflows"),
            ])
        }
    }

    private func featureGroup(_ title: String, icon: String, color: Color,
                              features: [(HubDestination, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(features, id: \.0) { dest, name, desc in
                    Button { trackFeature(dest); onNavigate(dest) } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.system(size: 10, weight: .medium)).foregroundColor(.primary).lineLimit(1)
                                Text(desc).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                        .padding(6)
                        .background(AppColors.backgroundSecondary.opacity(0.3))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(color.opacity(0.02))
        .cornerRadius(8)
    }

    // MARK: - Getting Started

    private var gettingStartedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Getting Started", icon: "arrow.right.circle", color: .mint)
            Text("Three steps to get the most out of your archive.")
                .font(.system(size: 10)).foregroundColor(.secondary)

            HStack(spacing: 10) {
                stepCard(step: 1, title: "Explore", description: "Browse your emails and see top contacts", icon: "magnifyingglass", color: .blue) {
                    trackFeature(.emailInbox); onNavigate(.emailInbox)
                }
                stepCard(step: 2, title: "Ask AI", description: "Natural language questions about your archive", icon: "sparkles", color: .purple) {
                    trackFeature(.aiAssistant); onNavigate(.aiAssistant)
                }
                stepCard(step: 3, title: "Analyze", description: "Charts, patterns, and insights", icon: "chart.bar", color: .green) {
                    trackFeature(.emailAnalytics); onNavigate(.emailAnalytics)
                }
            }
        }
    }

    private func stepCard(step: Int, title: String, description: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ZStack {
                        Circle().fill(color).frame(width: 22, height: 22)
                        Text("\(step)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    }
                    Spacer()
                    Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
                }
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(description).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recently Used

    private var recentlyUsedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recently Visited", icon: "clock.arrow.circlepath", color: .gray)
            HStack(spacing: 8) {
                ForEach(recentFeatures.prefix(4), id: \.self) { dest in
                    Button {
                        onNavigate(dest)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 8))
                            Text(formatDestinationName(dest))
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(AppColors.backgroundSecondary.opacity(0.5))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func trackFeature(_ dest: HubDestination) {
        recentFeatures.removeAll { $0 == dest }
        recentFeatures.insert(dest, at: 0)
        if recentFeatures.count > 6 { recentFeatures = Array(recentFeatures.prefix(6)) }
    }

    // MARK: - Tips

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Tips & Tricks", icon: "lightbulb", color: .yellow)
                Spacer()
                Button { showTips = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            tipRow("Use the AI Assistant to ask natural language questions about your emails")
            tipRow("Topic Clusters automatically groups your emails by theme using NLP")
            tipRow("The Timeline view helps you see patterns in email activity over time")
            tipRow("Export reports as PDF for sharing with colleagues")
            tipRow("Switch personas in Settings to get a tailored experience for your role")
        }
        .padding(12)
        .background(Color.yellow.opacity(0.04))
        .cornerRadius(8)
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundColor(.green)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Privacy Note

    private var privacyNote: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield.fill").font(.system(size: 9))
            Text("All analysis runs 100% on-device. Your emails never leave your Mac.")
                .font(.system(size: 9))
        }
        .foregroundColor(.secondary.opacity(0.6))
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
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

    private func formatDestinationName(_ dest: HubDestination) -> String {
        let raw = dest.rawValue
        var result = ""
        for char in raw {
            if char.isUppercase && !result.isEmpty { result += " " }
            result += String(char)
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    private func extractDomain(from address: String) -> String {
        let cleaned = address.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        guard let atIndex = cleaned.lastIndex(of: "@") else { return "" }
        return String(cleaned[cleaned.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func computeDateRange() -> String {
        let dates = emails.compactMap { MBOXParser.parseDate($0.headers["Date"] ?? "") }
        guard let first = dates.min(), let last = dates.max() else { return "N/A" }
        let f = DateFormatter()
        f.dateFormat = "MMM yy"
        return "\(f.string(from: first))-\(f.string(from: last))"
    }
}

// MARK: - FlowLayout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? .infinity, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
