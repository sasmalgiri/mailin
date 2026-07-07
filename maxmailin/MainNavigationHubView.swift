import SwiftUI

// MARK: - Hub Navigation Destination

enum HubDestination: String, Hashable {
    case emailInbox
    case eDiscovery, predictiveCoding, gdprCompliance
    case anomalyDetection, iocExtractor, smartAlerts, keywordMonitor, nearDuplicates, chainOfCustody
    case emailAnalytics, topicClusters, timeline, communicationPatterns, relationshipGraph
    case duplicateManager, threadSummarizer, attachmentGallery, executiveDashboard
    case reportBuilder, batchOperations, archiveComparison, forensicReview
    case investigationReport, batesNumbering, redaction, automationRules
    case aiAssistant, aiDigest, smartAutoTagger, customExperts
    case knowledgeGraphExplorer, aiVisualizations, backgroundFindings
    case predictiveInsights, pluginManager
    case personaHub
    case reviewBatches, custodianPanel, workspaceManager
    case legalWorkspace, itAdminDashboard, journalistWorkbench, personalOrganizer, generalExplorer
    case settings

    /// The minimum subscription tier required to actually use this destination.
    /// Used to render lock badges in the sidebar; access is enforced separately
    /// via `StoreManager.requirePremium()` / `requireProfessional()` on tap.
    var requiredTier: PurchaseTier {
        switch self {
        // Free — basic navigation and personal-tier surfaces
        case .emailInbox, .customExperts, .workspaceManager,
             .personalOrganizer, .generalExplorer, .personaHub, .settings:
            return .free
        // Professional — legal, forensic, compliance, IOC
        case .eDiscovery, .predictiveCoding, .gdprCompliance, .chainOfCustody,
             .forensicReview, .investigationReport, .batesNumbering,
             .reviewBatches, .custodianPanel, .legalWorkspace, .iocExtractor:
            return .professional
        // Personal — premium analytics, AI, automation
        default:
            return .personal
        }
    }
}

// MARK: - Main Navigation Hub

struct MainNavigationHubView: View {
    let emailCount: Int
    let filteredCount: Int
    let persona: PersonaManager.Persona
    let onNavigate: (HubDestination) -> Void
    let onOpenArchive: () -> Void
    let onNewImport: () -> Void
    let onSettings: () -> Void

    @Environment(\.windowSizeClass) private var sizeClass

    private var gridColumns: Int {
        switch sizeClass {
        case .compact: return 2
        case .regular: return 3
        case .expanded: return 4
        }
    }

    private var featureColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.small), count: gridColumns)
    }

    private var workflowColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.small), count: min(gridColumns, 3))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.large) {
                headerSection
                emailInboxHero
                personaWorkflowSection
                personaCoreFeaturesSection
                forYouSection
                personaOrderedSections
                formatsBar
                privacyTagline
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
        }
        .background(AppColors.backgroundPrimary)
    }

    @ViewBuilder
    private var personaOrderedSections: some View {
        switch persona {
        case .forensic:
            securitySection
            legalForensicSection
            analysisSection
            exportSection
            aiSection
        case .legal:
            legalForensicSection
            exportSection
            analysisSection
            aiSection
        case .itAdmin:
            securitySection
            analysisSection
            exportSection
            aiSection
        case .journalist:
            analysisSection
            aiSection
            exportSection
        case .personal:
            aiSection
            analysisSection
            exportSection
        case .general:
            analysisSection
            aiSection
            exportSection
        }
    }

    // MARK: - Persona Core Features

    private var personaCoreFeaturesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.xSmall) {
                sectionHeader(title: personaCoreFeaturesTitle, icon: persona.icon, color: persona.accentColor)
                Spacer()
                Text("CORE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(persona.accentColor))
            }

            LazyVGrid(columns: workflowColumns, spacing: Spacing.small) {
                ForEach(personaCoreFeatureTiles, id: \.0) { tile in
                    hubTile(dest: tile.0, title: tile.1, subtitle: tile.2, icon: tile.3, color: tile.4)
                }
            }
        }
    }

    private var personaCoreFeaturesTitle: String {
        switch persona {
        case .forensic: return "Forensic Tools"
        case .legal: return "Legal Tools"
        case .itAdmin: return "Admin Tools"
        case .journalist: return "Investigation Tools"
        case .personal: return "Organizer Tools"
        case .general: return "Explorer Tools"
        }
    }

    private var personaCoreFeatureTiles: [(HubDestination, String, String, String, Color)] {
        switch persona {
        case .forensic:
            return [
                (.forensicReview, "Evidence Coding", "Code & tag evidence", "shield.checkered", .orange),
                (.chainOfCustody, "Chain of Custody", "Track evidence handling", "link", .orange),
                (.iocExtractor, "IOC Detection", "Threat indicators", "exclamationmark.shield", .red),
                (.anomalyDetection, "Anomaly Detection", "Statistical outliers", "waveform.path.ecg", .red),
                (.investigationReport, "Investigation Reports", "Court-ready documents", "doc.text.magnifyingglass", .red),
            ]
        case .legal:
            return [
                (.legalWorkspace, "Privilege Review", "Code privilege & responsiveness", "building.columns", .indigo),
                (.eDiscovery, "eDiscovery Workflow", "EDRM process", "checklist", .blue),
                (.batesNumbering, "Bates Numbering", "Production stamping", "number", .purple),
                (.gdprCompliance, "GDPR Compliance", "Data protection reports", "hand.raised", .green),
                (.predictiveCoding, "Predictive Coding", "TAR classification", "brain", .pink),
            ]
        case .itAdmin:
            return [
                (.itAdminDashboard, "Header Analysis", "Headers, MIME, routing", "server.rack", .teal),
                (.smartAlerts, "Auth Verification", "SPF / DKIM / DMARC", "checkmark.shield", .green),
                (.anomalyDetection, "Anomaly Detection", "Unusual patterns", "waveform.path.ecg", .red),
                (.iocExtractor, "IOC Extraction", "Threat indicators", "exclamationmark.shield", .red),
                (.keywordMonitor, "Keyword Monitor", "Term tracking", "text.magnifyingglass", .teal),
            ]
        case .journalist:
            return [
                (.journalistWorkbench, "Source Tracking", "Sources & credibility", "newspaper", .purple),
                (.timeline, "Timeline Builder", "Event chronology", "calendar.day.timeline.left", .purple),
                (.communicationPatterns, "Network Mapping", "Contact connections", "person.2", .cyan),
                (.topicClusters, "Topic Discovery", "NLP clustering", "circle.grid.3x3", .teal),
                (.relationshipGraph, "Relationship Graph", "Who connects to whom", "point.3.connected.trianglepath.dotted", .mint),
            ]
        case .personal:
            return [
                (.personalOrganizer, "Smart Categories", "Auto-classify emails", "tray.full", .blue),
                (.emailAnalytics, "Contact Insights", "Stats & sentiment", "person.crop.circle", .cyan),
                (.attachmentGallery, "Attachments", "Photos & files", "paperclip", .brown),
                (.duplicateManager, "Cleanup", "Remove duplicates", "doc.on.doc", .indigo),
                (.threadSummarizer, "Summarizer", "Thread TL;DR", "text.bubble", .green),
            ]
        case .general:
            return [
                (.aiAssistant, "AI Assistant", "Ask anything", "sparkles", .purple),
                (.emailAnalytics, "Full Analytics", "Stats & charts", "chart.bar", .blue),
                (.knowledgeGraphExplorer, "Knowledge Graph", "Entity relationships", "point.3.connected.trianglepath.dotted", .purple),
                (.predictiveInsights, "Predictions", "Urgency & outcomes", "chart.line.uptrend.xyaxis", .red),
                (.pluginManager, "Plugins", "Extensions & add-ons", "puzzlepiece.extension", .indigo),
            ]
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 28))
                .foregroundStyle(
                    .linearGradient(colors: [persona.accentColor, persona.accentColor.opacity(0.5)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text("mailin")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                HStack(spacing: Spacing.xxSmall) {
                    Image(systemName: persona.icon)
                        .font(.caption2)
                    Text(persona.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(persona.accentColor)
            }

            Spacer()

            HStack(spacing: Spacing.small) {
                hubHeaderButton(icon: "plus.circle", label: "Add Files") { onOpenArchive() }
                hubHeaderButton(icon: "house", label: "New Import") { onNewImport() }
                hubHeaderButton(icon: "gearshape", label: "Settings") { onSettings() }
            }
        }
    }

    private func hubHeaderButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(AppColors.secondary)
            .frame(minWidth: 56, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Email Inbox Hero

    private var emailInboxHero: some View {
        Button { onNavigate(.emailInbox) } label: {
            HStack(spacing: Spacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .fill(
                            LinearGradient(colors: [persona.accentColor, persona.accentColor.opacity(0.6)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: "envelope.open.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Email Inbox")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text("\(emailCount) emails\(filteredCount != emailCount ? " · \(filteredCount) filtered" : "")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.large)
                            .strokeBorder(persona.accentColor.opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Email Inbox, \(emailCount) emails")
    }

    // MARK: - Persona Workflow (Featured Row)

    @ViewBuilder
    private var personaWorkflowSection: some View {
        switch persona {
        case .forensic:
            personaHero(
                title: "Forensic Review", subtitle: "Evidence coding, eDiscovery, chain of custody",
                icon: "shield.checkered", color: .orange, destination: .forensicReview
            )
            workflowRow(
                title: "eDiscovery Workflow", icon: "checklist", color: .blue,
                tiles: [
                    (.eDiscovery, "eDiscovery", "EDRM Workflow", "checklist", .blue),
                    (.predictiveCoding, "Predictive Coding", "TAR Classifier", "brain", .pink),
                    (.gdprCompliance, "GDPR Compliance", "Data Protection", "hand.raised", .green),
                ]
            )
        case .legal:
            personaHero(
                title: "Legal Review Workspace", subtitle: "Privilege coding, responsiveness, production sets",
                icon: "building.columns", color: .indigo, destination: .legalWorkspace
            )
            workflowRow(
                title: "Legal Workflow", icon: "building.columns", color: .indigo,
                tiles: [
                    (.eDiscovery, "eDiscovery", "EDRM Workflow", "checklist", .blue),
                    (.batesNumbering, "Bates Numbering", "Production stamping", "number", .purple),
                    (.gdprCompliance, "GDPR Compliance", "Data Protection", "hand.raised", .green),
                ]
            )
        case .itAdmin:
            personaHero(
                title: "IT Admin Analysis", subtitle: "Headers, authentication, routing, MIME structure",
                icon: "server.rack", color: .teal, destination: .itAdminDashboard
            )
            workflowRow(
                title: "Security Operations", icon: "shield", color: .red,
                tiles: [
                    (.iocExtractor, "IOC Extractor", "Threat indicators", "exclamationmark.shield", .red),
                    (.anomalyDetection, "Anomaly Detection", "Outlier analysis", "waveform.path.ecg", .red),
                    (.smartAlerts, "Smart Alerts", "Pattern monitoring", "bell.badge", .orange),
                ]
            )
        case .journalist:
            personaHero(
                title: "Investigation Workbench", subtitle: "Sources, timeline, leads, key quotes",
                icon: "newspaper", color: .purple, destination: .journalistWorkbench
            )
            workflowRow(
                title: "Research Tools", icon: "magnifyingglass", color: .purple,
                tiles: [
                    (.timeline, "Timeline", "Event chronology", "calendar.day.timeline.left", .purple),
                    (.relationshipGraph, "Relationship Graph", "Contact network", "point.3.connected.trianglepath.dotted", .mint),
                    (.communicationPatterns, "Comm Patterns", "Who talks to whom", "person.2", .cyan),
                ]
            )
        case .personal:
            personaHero(
                title: "Personal Organizer", subtitle: "Contacts, categories, attachments, cleanup",
                icon: "tray.full", color: .blue, destination: .personalOrganizer
            )
            workflowRow(
                title: "Quick Actions", icon: "star", color: .blue,
                tiles: [
                    (.attachmentGallery, "Attachments", "Photos & files", "paperclip", .brown),
                    (.duplicateManager, "Cleanup", "Remove duplicates", "doc.on.doc", .indigo),
                    (.threadSummarizer, "Summarize", "Thread TL;DR", "text.bubble", .green),
                ]
            )
        case .general:
            personaHero(
                title: "Feature Explorer", subtitle: "Discover all features, tips, and guided tour",
                icon: "sparkles", color: .mint, destination: .generalExplorer
            )
            workflowRow(
                title: "Get Started", icon: "sparkles", color: .mint,
                tiles: [
                    (.aiAssistant, "AI Assistant", "Ask anything", "sparkles", .purple),
                    (.emailAnalytics, "Analytics", "Stats & charts", "chart.bar", .blue),
                    (.executiveDashboard, "Dashboard", "KPI overview", "gauge.with.dots.needle.33percent", .blue),
                ]
            )
        }
    }

    private func personaHero(title: String, subtitle: String, icon: String, color: Color, destination: HubDestination) -> some View {
        Button { onNavigate(destination) } label: {
            HStack(spacing: Spacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .fill(
                            LinearGradient(colors: [color, color.opacity(0.6)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.large)
                            .strokeBorder(color.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(title)")
    }

    private func workflowRow(title: String, icon: String, color: Color,
                             tiles: [(HubDestination, String, String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader(title: title, icon: icon, color: color)
            LazyVGrid(columns: workflowColumns, spacing: Spacing.small) {
                ForEach(tiles, id: \.0) { tile in
                    hubTile(dest: tile.0, title: tile.1, subtitle: tile.2, icon: tile.3, color: tile.4)
                }
            }
        }
    }

    // MARK: - For You (Persona-Recommended)

    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.xSmall) {
                sectionHeader(title: forYouTitle, icon: forYouIcon, color: forYouColor)
                Spacer()
                Text("FOR YOU")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(persona.accentColor))
            }

            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                ForEach(forYouTiles, id: \.0) { tile in
                    hubTile(dest: tile.0, title: tile.1, subtitle: tile.2, icon: tile.3, color: tile.4)
                }
            }
        }
    }

    private var forYouTitle: String {
        switch persona {
        case .forensic: return "Security & Detection"
        case .legal: return "Privilege & Compliance"
        case .itAdmin: return "Technical Analysis"
        case .journalist: return "Discovery & Research"
        case .personal: return "Organize & Find"
        case .general: return "Popular Features"
        }
    }

    private var forYouIcon: String {
        switch persona {
        case .forensic: return "shield.checkered"
        case .legal: return "lock.shield"
        case .itAdmin: return "network"
        case .journalist: return "magnifyingglass"
        case .personal: return "tray.full"
        case .general: return "star"
        }
    }

    private var forYouColor: Color {
        switch persona {
        case .forensic: return .red
        case .legal: return .indigo
        case .itAdmin: return .teal
        case .journalist: return .purple
        case .personal: return .blue
        case .general: return .orange
        }
    }

    private var forYouTiles: [(HubDestination, String, String, String, Color)] {
        switch persona {
        case .forensic:
            return [
                (.anomalyDetection, "Anomaly Detection", "Statistical outliers", "waveform.path.ecg", .red),
                (.iocExtractor, "IOC Extractor", "Threat indicators", "exclamationmark.shield", .red),
                (.smartAlerts, "Smart Alerts", "Pattern monitoring", "bell.badge", .orange),
                (.keywordMonitor, "Keyword Monitor", "Term tracking", "text.magnifyingglass", .teal),
                (.nearDuplicates, "Near Duplicates", "Similarity detection", "square.on.square.dashed", .indigo),
                (.chainOfCustody, "Chain of Custody", "Evidence tracking", "link", .orange),
            ]
        case .legal:
            return [
                (.gdprCompliance, "GDPR Compliance", "Data protection", "hand.raised", .green),
                (.redaction, "Redaction", "PII removal", "eye.slash", .gray),
                (.reviewBatches, "Review Batches", "Batch workflow", "list.bullet.rectangle", .mint),
                (.custodianPanel, "Custodian Panel", "Data custodians", "person.badge.key", .cyan),
                (.predictiveCoding, "Predictive Coding", "TAR Classifier", "brain", .pink),
                (.keywordMonitor, "Keyword Monitor", "Term tracking", "text.magnifyingglass", .teal),
            ]
        case .itAdmin:
            return [
                (.keywordMonitor, "Keyword Monitor", "Term tracking", "text.magnifyingglass", .teal),
                (.nearDuplicates, "Near Duplicates", "Similarity detection", "square.on.square.dashed", .indigo),
                (.duplicateManager, "Duplicate Manager", "Find & remove", "doc.on.doc", .indigo),
                (.communicationPatterns, "Comm Patterns", "Traffic analysis", "person.2", .cyan),
                (.attachmentGallery, "Attachments", "File gallery", "paperclip", .brown),
                (.archiveComparison, "Archive Compare", "Diff archives", "rectangle.on.rectangle.angled", .cyan),
            ]
        case .journalist:
            return [
                (.topicClusters, "Topic Clusters", "NLP grouping", "circle.grid.3x3", .teal),
                (.threadSummarizer, "Thread Summarizer", "Conversation TL;DR", "text.bubble", .green),
                (.emailAnalytics, "Email Analytics", "Comprehensive stats", "chart.bar", .blue),
                (.executiveDashboard, "Executive Dashboard", "KPI overview", "gauge.with.dots.needle.33percent", .blue),
                (.anomalyDetection, "Anomaly Detection", "Outlier patterns", "waveform.path.ecg", .red),
                (.redaction, "Redaction", "Source protection", "eye.slash", .gray),
            ]
        case .personal:
            return [
                (.topicClusters, "Topic Clusters", "Organize by topic", "circle.grid.3x3", .teal),
                (.emailAnalytics, "Email Analytics", "Your email stats", "chart.bar", .blue),
                (.timeline, "Timeline", "Chronological view", "calendar.day.timeline.left", .purple),
                (.nearDuplicates, "Near Duplicates", "Find similar", "square.on.square.dashed", .indigo),
            ]
        case .general:
            return [
                (.topicClusters, "Topic Clusters", "NLP grouping", "circle.grid.3x3", .teal),
                (.timeline, "Timeline", "Chronological view", "calendar.day.timeline.left", .purple),
                (.communicationPatterns, "Comm Patterns", "Contact analysis", "person.2", .cyan),
                (.relationshipGraph, "Relationship Graph", "Network map", "point.3.connected.trianglepath.dotted", .mint),
                (.duplicateManager, "Duplicate Manager", "Find & remove", "doc.on.doc", .indigo),
                (.attachmentGallery, "Attachments", "File gallery", "paperclip", .brown),
            ]
        }
    }

    // MARK: - Analysis & Insights

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader(title: "Analysis & Insights", icon: "chart.bar", color: .blue)

            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                hubTile(dest: .emailAnalytics, title: "Email Analytics", subtitle: "Comprehensive stats",
                        icon: "chart.bar", color: .blue)
                hubTile(dest: .topicClusters, title: "Topic Clusters", subtitle: "NLP grouping",
                        icon: "circle.grid.3x3", color: .teal)
                hubTile(dest: .timeline, title: "Timeline", subtitle: "Chronological view",
                        icon: "calendar.day.timeline.left", color: .purple)
                hubTile(dest: .communicationPatterns, title: "Comm Patterns", subtitle: "Contact analysis",
                        icon: "person.2", color: .cyan)
                hubTile(dest: .relationshipGraph, title: "Relationship Graph", subtitle: "Network map",
                        icon: "point.3.connected.trianglepath.dotted", color: .mint)
                hubTile(dest: .duplicateManager, title: "Duplicate Manager", subtitle: "Find & remove",
                        icon: "doc.on.doc", color: .indigo)
                hubTile(dest: .threadSummarizer, title: "Thread Summarizer", subtitle: "Conversation TL;DR",
                        icon: "text.bubble", color: .green)
                hubTile(dest: .attachmentGallery, title: "Attachments", subtitle: "File gallery",
                        icon: "paperclip", color: .brown)
                hubTile(dest: .executiveDashboard, title: "Executive Dashboard", subtitle: "KPI overview",
                        icon: "gauge.with.dots.needle.33percent", color: .blue)
            }
        }
    }

    // MARK: - Security & Detection

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader(title: "Security & Detection", icon: "shield.checkered", color: .red)

            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                hubTile(dest: .anomalyDetection, title: "Anomaly Detection", subtitle: "Statistical outliers",
                        icon: "waveform.path.ecg", color: .red)
                hubTile(dest: .iocExtractor, title: "IOC Extractor", subtitle: "Threat indicators",
                        icon: "exclamationmark.shield", color: .red)
                hubTile(dest: .smartAlerts, title: "Smart Alerts", subtitle: "Pattern monitoring",
                        icon: "bell.badge", color: .orange)
                hubTile(dest: .keywordMonitor, title: "Keyword Monitor", subtitle: "Term tracking",
                        icon: "text.magnifyingglass", color: .teal)
                hubTile(dest: .nearDuplicates, title: "Near Duplicates", subtitle: "Similarity detection",
                        icon: "square.on.square.dashed", color: .indigo)
                hubTile(dest: .chainOfCustody, title: "Chain of Custody", subtitle: "Evidence tracking",
                        icon: "link", color: .orange)
            }
        }
    }

    // MARK: - Legal & Forensic

    private var legalForensicSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader(title: "Legal & Forensic", icon: "building.columns", color: .indigo)

            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                hubTile(dest: .eDiscovery, title: "eDiscovery", subtitle: "EDRM Workflow",
                        icon: "checklist", color: .blue)
                hubTile(dest: .predictiveCoding, title: "Predictive Coding", subtitle: "TAR Classifier",
                        icon: "brain", color: .pink)
                hubTile(dest: .forensicReview, title: "Document Review", subtitle: "Evidence coding",
                        icon: "shield.checkered", color: .orange)
                hubTile(dest: .gdprCompliance, title: "GDPR Compliance", subtitle: "Data Protection",
                        icon: "hand.raised", color: .green)
                hubTile(dest: .investigationReport, title: "Investigation Report", subtitle: "Court-ready docs",
                        icon: "doc.text.magnifyingglass", color: .red)
                hubTile(dest: .batesNumbering, title: "Bates Numbers", subtitle: "Document stamping",
                        icon: "number", color: .purple)
                hubTile(dest: .reviewBatches, title: "Review Batches", subtitle: "Batch workflow",
                        icon: "list.bullet.rectangle", color: .mint)
                hubTile(dest: .custodianPanel, title: "Custodian Panel", subtitle: "Data custodians",
                        icon: "person.badge.key", color: .cyan)
            }
        }
    }

    // MARK: - Export & Reports

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader(title: "Export & Reports", icon: "doc.text", color: .orange)

            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                hubTile(dest: .reportBuilder, title: "Report Builder", subtitle: "PDF generation",
                        icon: "doc.richtext", color: .blue)
                hubTile(dest: .batchOperations, title: "Batch Operations", subtitle: "Bulk actions",
                        icon: "square.stack.3d.up", color: .orange)
                hubTile(dest: .archiveComparison, title: "Archive Compare", subtitle: "Diff archives",
                        icon: "rectangle.on.rectangle.angled", color: .cyan)
                hubTile(dest: .redaction, title: "Redaction", subtitle: "PII removal",
                        icon: "eye.slash", color: .gray)
                hubTile(dest: .automationRules, title: "Automation Rules", subtitle: "Custom workflows",
                        icon: "gearshape.2", color: .indigo)
            }
        }
    }

    // MARK: - AI Intelligence

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            sectionHeader(title: "AI Intelligence", icon: "sparkles", color: .purple)

            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                hubTile(dest: .aiAssistant, title: "AI Assistant", subtitle: "Ask anything",
                        icon: "sparkles", color: .purple)
                hubTile(dest: .aiDigest, title: "AI Digest", subtitle: "Smart summary",
                        icon: "newspaper", color: .blue)
                hubTile(dest: .smartAutoTagger, title: "Auto-Tagger", subtitle: "NLP classification",
                        icon: "tag", color: .teal)
                hubTile(dest: .customExperts, title: "Custom Experts", subtitle: "Expert config",
                        icon: "person.crop.rectangle.stack", color: .mint)
                hubTile(dest: .knowledgeGraphExplorer, title: "Knowledge Graph", subtitle: "Entity relationships",
                        icon: "point.3.connected.trianglepath.dotted", color: .purple)
                hubTile(dest: .aiVisualizations, title: "AI Visualizations", subtitle: "Charts & heatmaps",
                        icon: "chart.bar.xaxis.ascending", color: .blue)
                hubTile(dest: .backgroundFindings, title: "Background Scan", subtitle: "Proactive detection",
                        icon: "shield.lefthalf.filled.badge.checkmark", color: .orange)
                hubTile(dest: .predictiveInsights, title: "Predictions", subtitle: "Urgency & outcomes",
                        icon: "chart.line.uptrend.xyaxis", color: .red)
                hubTile(dest: .pluginManager, title: "Plugins", subtitle: "Extensions & add-ons",
                        icon: "puzzlepiece.extension", color: .indigo)
                hubTile(dest: .workspaceManager, title: "Workspaces", subtitle: "Multi-archive",
                        icon: "square.grid.2x2", color: .gray)
            }
        }
    }

    // MARK: - Bottom Bar

    private var formatsBar: some View {
        VStack(spacing: Spacing.xSmall) {
            Divider()
            HStack(spacing: Spacing.medium) {
                Text("Supported Formats")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: Spacing.xSmall) {
                    formatBadge(".mbox")
                    formatBadge(".eml")
                    formatBadge(".emlx")
                    formatBadge(".msg")
                    formatBadge(".pst")
                    formatBadge(".ost")
                    formatBadge(".nsf")
                    formatBadge(".zip")
                }
            }
        }
    }

    private func formatBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppColors.backgroundSecondary)
            .cornerRadius(CornerRadius.small)
    }

    private var privacyTagline: some View {
        HStack(spacing: Spacing.xxSmall) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 10))
            Text("100% on-device processing · Your emails never leave your Mac")
                .font(.system(size: 10))
        }
        .foregroundColor(.secondary.opacity(0.7))
        .padding(.bottom, Spacing.small)
    }

    // MARK: - Components

    private func sectionHeader(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.primary)
        }
    }

    private func hubTile(dest: HubDestination, title: String, subtitle: String,
                         icon: String, color: Color) -> some View {
        Button { onNavigate(dest) } label: {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
                    .frame(height: 26)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(color.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .strokeBorder(color.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}
