import SwiftUI

// MARK: - Hub Navigation Destination

enum HubDestination: String, Hashable {
    case emailInbox
    case eDiscovery, predictiveCoding, gdprCompliance
    case anomalyDetection, iocExtractor, smartAlerts, keywordMonitor, nearDuplicates, chainOfCustody
    case phishingTriage, reviewDashboard, storyFile, workCenter
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
             .reviewBatches, .custodianPanel, .legalWorkspace, .iocExtractor,
             .phishingTriage, .reviewDashboard:
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
    /// The guided workflow to run, presented as a sheet (same pattern as
    /// Work Center) — set by tapping a "Start a job" card.
    @State private var workflowToRun: WorkflowDefinition?
    /// Comma-joined recent tool destinations (written by ContentView), so the
    /// hub can offer a one-tap "jump back to what you were doing" row.
    @AppStorage("recentTools") private var recentToolsRaw = ""

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

    // MARK: - Tile / section model (de-duplicated, data-driven)

    /// One tool tile. A destination appears in AT MOST one rendered section —
    /// de-duplication is enforced at render time so there's clear ownership.
    struct HubTile: Identifiable {
        let dest: HubDestination
        let title: String
        let subtitle: String
        let icon: String
        let color: Color
        var id: HubDestination { dest }
    }

    struct ToolSection: Identifiable {
        let title: String
        let icon: String
        let color: Color
        let tiles: [HubTile]
        var id: String { title }
    }

    private func t(_ dest: HubDestination, _ title: String, _ subtitle: String,
                   _ icon: String, _ color: Color) -> HubTile {
        HubTile(dest: dest, title: title, subtitle: subtitle, icon: icon, color: color)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.large) {
                headerSection
                emailInboxHero
                guidedWorkflowsSection
                personaHeroSection
                recentToolsSection
                ForEach(deDupedToolSections) { section in
                    toolSectionView(section)
                }
                formatsBar
                privacyTagline
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
        }
        .background(AppColors.backgroundPrimary)
        .sheet(item: $workflowToRun) { def in
            WorkflowRunnerView(
                definition: def,
                onOpenDestination: { dest in
                    workflowToRun = nil
                    onNavigate(dest)
                },
                onClose: { workflowToRun = nil }
            )
        }
    }

    // MARK: - Guided Workflows (pick the job you came to do)

    private var guidedWorkflows: [WorkflowDefinition] {
        let list = WorkflowCatalog.templates(for: persona.rawValue)
        return list.isEmpty ? WorkflowCatalog.all : list
    }

    @ViewBuilder
    private var guidedWorkflowsSection: some View {
        if !guidedWorkflows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.xSmall) {
                    sectionHeader(title: "Start a job", icon: "flowchart", color: persona.accentColor)
                    Spacer()
                    Text("GUIDED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(persona.accentColor))
                }
                Text("Pick what you came to do — mailin runs each step and keeps the numbered record for you.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                LazyVGrid(columns: workflowColumns, spacing: Spacing.small) {
                    ForEach(guidedWorkflows) { def in
                        workflowCard(def)
                    }
                }
            }
        }
    }

    /// macOS: open the run in its own window. iOS: fall back to a sheet.
    private func startWorkflow(_ def: WorkflowDefinition) {
        let opened = WorkflowWindow.open(
            definition: def,
            onOpenDestination: { onNavigate($0) })
        if !opened { workflowToRun = def }
    }

    private func workflowCard(_ def: WorkflowDefinition) -> some View {
        Button { startWorkflow(def) } label: {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: workflowIcon(def.defID))
                        .font(.system(size: 20))
                        .foregroundColor(persona.accentColor)
                        .frame(width: 26, height: 26)
                    Text(def.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer()
                }
                Text(WorkflowCatalog.purpose(for: def.defID))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(def.operations.map(\.title).joined(separator: " → "))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text("Start")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 12))
                }
                .foregroundColor(persona.accentColor)
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .padding(Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(persona.accentColor.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .strokeBorder(persona.accentColor.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start workflow: \(def.name)")
        .help(WorkflowCatalog.purpose(for: def.defID))
    }

    private func workflowIcon(_ defID: String) -> String {
        switch defID {
        case "builtin.forensic.intake": return "shield.checkered"
        case "builtin.forensic.timeline": return "calendar.day.timeline.left"
        case "builtin.forensic.keywordsweep": return "text.magnifyingglass"
        case "builtin.forensic.custodyverify": return "checkmark.seal"
        case "builtin.legal.production": return "building.columns"
        case "builtin.legal.hold": return "hand.raised"
        case "builtin.legal.eca": return "chart.bar.doc.horizontal"
        case "builtin.legal.dsar": return "person.text.rectangle"
        case "builtin.it.phishing": return "shield.lefthalf.filled"
        case "builtin.it.threathunt": return "binoculars"
        case "builtin.it.campaign": return "square.grid.3x3.fill"
        case "builtin.it.bec": return "person.badge.shield.checkmark"
        case "builtin.journalist.story": return "text.book.closed"
        case "builtin.journalist.network": return "point.3.connected.trianglepath.dotted"
        case "builtin.journalist.factcheck": return "checkmark.bubble"
        case "builtin.journalist.publish": return "eye.slash"
        case "builtin.personal.cleanup": return "sparkles"
        case "builtin.personal.findexport": return "magnifyingglass"
        case "builtin.personal.declutter": return "trash"
        case "builtin.forensic.exhibit": return "doc.zipper"
        case "builtin.forensic.insider": return "person.crop.circle.badge.exclamationmark"
        case "builtin.legal.privqc": return "checkmark.shield"
        case "builtin.legal.compliance": return "checklist"
        case "builtin.it.authaudit": return "lock.shield"
        case "builtin.it.metrics": return "chart.bar.doc.horizontal"
        case "builtin.journalist.tips": return "tray.and.arrow.down"
        case "builtin.journalist.datapack": return "chart.bar.xaxis"
        case "builtin.personal.receipts": return "doc.text.magnifyingglass"
        case "builtin.forensic.headers": return "envelope.badge.shield.half.filled"
        case "builtin.forensic.cull": return "line.3.horizontal.decrease.circle"
        case "builtin.forensic.iocreport": return "bolt.shield"
        case "builtin.forensic.affidavit": return "doc.text.magnifyingglass"
        case "builtin.legal.collection": return "tray.and.arrow.down.fill"
        case "builtin.legal.processing": return "gearshape.2"
        case "builtin.legal.firstpass": return "rectangle.stack.badge.play"
        case "builtin.legal.clawback": return "arrow.uturn.backward.circle"
        case "builtin.it.quarantine": return "tray.full"
        case "builtin.it.rules": return "gearshape.arrow.triangle.2.circlepath"
        case "builtin.it.blocklist": return "hand.raised.slash"
        case "builtin.it.dlp": return "arrow.up.right.square"
        case "builtin.journalist.provenance": return "checkmark.seal"
        case "builtin.journalist.foia": return "envelope.open"
        case "builtin.journalist.quotes": return "quote.bubble"
        case "builtin.journalist.crossref": return "rectangle.on.rectangle.angled"
        case "builtin.personal.backup": return "externaldrive.badge.timemachine"
        case "builtin.personal.attachments": return "paperclip"
        case "builtin.personal.contacts": return "person.2.crop.square.stack"
        default: return "flowchart"
        }
    }

    // MARK: - Persona hero (the one featured workspace banner)

    private var personaHeroSection: some View {
        personaHero(
            title: heroTitle, subtitle: heroSubtitle,
            icon: heroIcon, color: heroColor, destination: heroDestination
        )
    }

    private var heroDestination: HubDestination {
        switch persona {
        case .forensic: return .forensicReview
        case .legal: return .legalWorkspace
        case .itAdmin: return .itAdminDashboard
        case .journalist: return .journalistWorkbench
        case .personal: return .personalOrganizer
        case .general: return .generalExplorer
        }
    }
    private var heroTitle: String {
        switch persona {
        case .forensic: return "Forensic Review"
        case .legal: return "Legal Review Workspace"
        case .itAdmin: return "IT Admin Analysis"
        case .journalist: return "Investigation Workbench"
        case .personal: return "Personal Organizer"
        case .general: return "Feature Explorer"
        }
    }
    private var heroSubtitle: String {
        switch persona {
        case .forensic: return "Evidence coding, eDiscovery, chain of custody"
        case .legal: return "Privilege coding, responsiveness, production sets"
        case .itAdmin: return "Headers, authentication, routing, MIME structure"
        case .journalist: return "Sources, timeline, leads, key quotes"
        case .personal: return "Contacts, categories, attachments, cleanup"
        case .general: return "Discover all features, tips, and guided tour"
        }
    }
    private var heroIcon: String {
        switch persona {
        case .forensic: return "shield.checkered"
        case .legal: return "building.columns"
        case .itAdmin: return "server.rack"
        case .journalist: return "newspaper"
        case .personal: return "tray.full"
        case .general: return "sparkles"
        }
    }
    private var heroColor: Color {
        switch persona {
        case .forensic: return .orange
        case .legal: return .indigo
        case .itAdmin: return .teal
        case .journalist: return .purple
        case .personal: return .blue
        case .general: return .mint
        }
    }

    // MARK: - Tool sections (each tool appears exactly once)

    /// The ordered raw sections for this persona — core first (persona's key
    /// tools + Work Center), then category sections. Rendering de-duplicates
    /// so a tool shown in an earlier section never repeats in a later one.
    private var rawSections: [ToolSection] {
        var out = [coreSection]
        // Strict persona isolation — each persona owns only the tool families
        // that fit its job. Switching persona reveals the others.
        switch persona {
        case .forensic:
            // No Legal & Forensic bucket — it carries legal-only tools
            // (eDiscovery, Bates, TAR, Review Dashboard). Forensic's own
            // legal-adjacent tools (Custodian Panel, Redaction) live in Core.
            out += [securitySection, analysisSection]
        case .legal:
            out += [legalForensicSection, exportSection]
        case .itAdmin:
            out += [securitySection, analysisSection]
        case .journalist:
            out += [analysisSection, aiSection]
        case .personal:
            out += [analysisSection]
        case .general:
            // Explorer keeps the full catalog.
            out += [securitySection, legalForensicSection, analysisSection, exportSection, aiSection]
        }
        return out
    }

    /// De-duplicate across sections in order. Email Inbox (hero above) and the
    /// persona workspace banner already own their destinations, so they're
    /// seeded as "seen" and won't reappear as tiles.
    private var deDupedToolSections: [ToolSection] {
        var seen: Set<HubDestination> = [.emailInbox, heroDestination]
        var out: [ToolSection] = []
        for raw in rawSections {
            let tiles = raw.tiles.filter { seen.insert($0.dest).inserted }
            if !tiles.isEmpty {
                out.append(ToolSection(title: raw.title, icon: raw.icon, color: raw.color, tiles: tiles))
            }
        }
        return out
    }

    // MARK: Recently used (recognition over recall)

    /// Every tool tile the app knows about, for looking up a recent dest.
    private var allTiles: [HubTile] {
        coreSection.tiles + analysisSection.tiles + securitySection.tiles
            + legalForensicSection.tiles + exportSection.tiles + aiSection.tiles
    }

    private var recentTools: [HubTile] {
        let dests = recentToolsRaw.split(separator: ",").compactMap { HubDestination(rawValue: String($0)) }
        let map = Dictionary(allTiles.map { ($0.dest, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(dests.compactMap { map[$0] }.prefix(6))
    }

    @ViewBuilder
    private var recentToolsSection: some View {
        if !recentTools.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.small) {
                sectionHeader(title: "Recently used", icon: "clock.arrow.circlepath", color: AppColors.secondary)
                LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                    ForEach(recentTools) { tile in
                        hubTile(tile)
                    }
                }
            }
        }
    }

    private func toolSectionView(_ section: ToolSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.xSmall) {
                sectionHeader(title: section.title, icon: section.icon, color: section.color)
                if section.title == coreTitle {
                    Spacer()
                    Text("CORE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(persona.accentColor))
                }
            }
            LazyVGrid(columns: featureColumns, spacing: Spacing.small) {
                ForEach(section.tiles) { tile in
                    hubTile(tile)
                }
            }
        }
    }

    // MARK: Core section (persona's headline tools)

    private var coreTitle: String {
        switch persona {
        case .forensic: return "Forensic Tools"
        case .legal: return "Legal Tools"
        case .itAdmin: return "Admin Tools"
        case .journalist: return "Investigation Tools"
        case .personal: return "Organizer Tools"
        case .general: return "Explorer Tools"
        }
    }

    private var coreSection: ToolSection {
        ToolSection(title: coreTitle, icon: persona.icon, color: persona.accentColor,
                    tiles: [t(.workCenter, "Work Center", "What's waiting on you", "tray.full.fill", .blue)] + personaCoreTiles)
    }

    private var personaCoreTiles: [HubTile] {
        switch persona {
        case .forensic:
            return [
                t(.forensicReview, "Evidence Coding", "Code & tag evidence", "shield.checkered", .orange),
                t(.chainOfCustody, "Chain of Custody", "Track evidence handling", "link", .orange),
                t(.iocExtractor, "IOC Detection", "Threat indicators", "exclamationmark.shield", .red),
                t(.anomalyDetection, "Anomaly Detection", "Statistical outliers", "waveform.path.ecg", .red),
                t(.investigationReport, "Investigation Reports", "Court-ready documents", "doc.text.magnifyingglass", .red),
                t(.custodianPanel, "Custodian Panel", "Track data custodians", "person.badge.key", .cyan),
                t(.redaction, "Redaction", "Protect PII in exhibits", "eye.slash", .gray),
            ]
        case .legal:
            return [
                t(.legalWorkspace, "Privilege Review", "Code privilege & responsiveness", "building.columns", .indigo),
                t(.eDiscovery, "eDiscovery Workflow", "EDRM process", "checklist", .blue),
                t(.batesNumbering, "Bates Numbering", "Production stamping", "number", .purple),
                t(.gdprCompliance, "GDPR Compliance", "Data protection reports", "hand.raised", .green),
                t(.predictiveCoding, "Predictive Coding", "TAR classification", "brain", .pink),
            ]
        case .itAdmin:
            return [
                t(.itAdminDashboard, "Header Analysis", "Headers, MIME, routing", "server.rack", .teal),
                t(.smartAlerts, "Auth Verification", "SPF / DKIM / DMARC", "checkmark.shield", .green),
                t(.anomalyDetection, "Anomaly Detection", "Unusual patterns", "waveform.path.ecg", .red),
                t(.iocExtractor, "IOC Extraction", "Threat indicators", "exclamationmark.shield", .red),
                t(.keywordMonitor, "Keyword Monitor", "Term tracking", "text.magnifyingglass", .teal),
            ]
        case .journalist:
            return [
                t(.journalistWorkbench, "Source Tracking", "Sources & credibility", "newspaper", .purple),
                t(.timeline, "Timeline Builder", "Event chronology", "calendar.day.timeline.left", .purple),
                t(.communicationPatterns, "Network Mapping", "Contact connections", "person.2", .cyan),
                t(.topicClusters, "Topic Discovery", "NLP clustering", "circle.grid.3x3", .teal),
                t(.relationshipGraph, "Relationship Graph", "Who connects to whom", "point.3.connected.trianglepath.dotted", .mint),
                t(.redaction, "Redaction", "Protect your sources", "eye.slash", .gray),
            ]
        case .personal:
            return [
                t(.personalOrganizer, "Smart Categories", "Auto-classify emails", "tray.full", .blue),
                t(.emailAnalytics, "Contact Insights", "Stats & sentiment", "person.crop.circle", .cyan),
                t(.attachmentGallery, "Attachments", "Photos & files", "paperclip", .brown),
                t(.duplicateManager, "Cleanup", "Remove duplicates", "doc.on.doc", .indigo),
                t(.threadSummarizer, "Summarizer", "Thread TL;DR", "text.bubble", .green),
            ]
        case .general:
            return [
                t(.aiAssistant, "AI Assistant", "Ask anything", "sparkles", .purple),
                t(.emailAnalytics, "Full Analytics", "Stats & charts", "chart.bar", .blue),
                t(.knowledgeGraphExplorer, "Knowledge Graph", "Entity relationships", "point.3.connected.trianglepath.dotted", .purple),
                t(.predictiveInsights, "Predictions", "Urgency & outcomes", "chart.line.uptrend.xyaxis", .red),
                t(.pluginManager, "Plugins", "Extensions & add-ons", "puzzlepiece.extension", .indigo),
            ]
        }
    }

    // MARK: Category sections (shared tool catalog — de-dup trims overlaps)

    private var analysisSection: ToolSection {
        ToolSection(title: "Analysis & Insights", icon: "chart.bar", color: .blue, tiles: [
            t(.emailAnalytics, "Email Analytics", "Comprehensive stats", "chart.bar", .blue),
            t(.topicClusters, "Topic Clusters", "NLP grouping", "circle.grid.3x3", .teal),
            t(.timeline, "Timeline", "Chronological view", "calendar.day.timeline.left", .purple),
            t(.communicationPatterns, "Comm Patterns", "Contact analysis", "person.2", .cyan),
            t(.relationshipGraph, "Relationship Graph", "Network map", "point.3.connected.trianglepath.dotted", .mint),
            t(.duplicateManager, "Duplicate Manager", "Find & remove", "doc.on.doc", .indigo),
            t(.threadSummarizer, "Thread Summarizer", "Conversation TL;DR", "text.bubble", .green),
            t(.attachmentGallery, "Attachments", "File gallery", "paperclip", .brown),
            t(.executiveDashboard, "Executive Dashboard", "KPI overview", "gauge.with.dots.needle.33percent", .blue),
        ])
    }

    private var securitySection: ToolSection {
        ToolSection(title: "Security & Detection", icon: "shield.checkered", color: .red, tiles: [
            t(.anomalyDetection, "Anomaly Detection", "Statistical outliers", "waveform.path.ecg", .red),
            t(.phishingTriage, "Phishing Triage", "Verdict queue", "shield.lefthalf.filled", .red),
            t(.iocExtractor, "IOC Extractor", "Threat indicators", "exclamationmark.shield", .red),
            t(.smartAlerts, "Smart Alerts", "Pattern monitoring", "bell.badge", .orange),
            t(.keywordMonitor, "Keyword Monitor", "Term tracking", "text.magnifyingglass", .teal),
            t(.nearDuplicates, "Near Duplicates", "Similarity detection", "square.on.square.dashed", .indigo),
            t(.chainOfCustody, "Chain of Custody", "Evidence tracking", "link", .orange),
        ])
    }

    private var legalForensicSection: ToolSection {
        ToolSection(title: "Legal & Forensic", icon: "building.columns", color: .indigo, tiles: [
            t(.eDiscovery, "eDiscovery", "EDRM Workflow", "checklist", .blue),
            t(.predictiveCoding, "Predictive Coding", "TAR Classifier", "brain", .pink),
            t(.forensicReview, "Document Review", "Evidence coding", "shield.checkered", .orange),
            t(.gdprCompliance, "GDPR Compliance", "Data Protection", "hand.raised", .green),
            t(.investigationReport, "Investigation Report", "Court-ready docs", "doc.text.magnifyingglass", .red),
            t(.batesNumbering, "Bates Numbers", "Document stamping", "number", .purple),
            t(.reviewBatches, "Review Batches", "Batch workflow", "list.bullet.rectangle", .mint),
            t(.reviewDashboard, "Review Dashboard", "Progress & privilege log", "chart.bar.doc.horizontal", .indigo),
            t(.custodianPanel, "Custodian Panel", "Data custodians", "person.badge.key", .cyan),
            t(.redaction, "Redaction", "PII / source protection", "eye.slash", .gray),
        ])
    }

    private var exportSection: ToolSection {
        ToolSection(title: "Export & Reports", icon: "doc.text", color: .orange, tiles: [
            t(.reportBuilder, "Report Builder", "PDF generation", "doc.richtext", .blue),
            t(.batchOperations, "Batch Operations", "Bulk actions", "square.stack.3d.up", .orange),
            t(.archiveComparison, "Archive Compare", "Diff archives", "rectangle.on.rectangle.angled", .cyan),
            t(.automationRules, "Automation Rules", "Custom workflows", "gearshape.2", .indigo),
        ])
    }

    private var aiSection: ToolSection {
        ToolSection(title: "AI Intelligence", icon: "sparkles", color: .purple, tiles: [
            t(.aiAssistant, "AI Assistant", "Ask anything", "sparkles", .purple),
            t(.aiDigest, "AI Digest", "Smart summary", "newspaper", .blue),
            t(.smartAutoTagger, "Auto-Tagger", "NLP classification", "tag", .teal),
            t(.customExperts, "Custom Experts", "Expert config", "person.crop.rectangle.stack", .mint),
            t(.knowledgeGraphExplorer, "Knowledge Graph", "Entity relationships", "point.3.connected.trianglepath.dotted", .purple),
            t(.aiVisualizations, "AI Visualizations", "Charts & heatmaps", "chart.bar.xaxis.ascending", .blue),
            t(.backgroundFindings, "Background Scan", "Proactive detection", "shield.lefthalf.filled.badge.checkmark", .orange),
            t(.predictiveInsights, "Predictions", "Urgency & outcomes", "chart.line.uptrend.xyaxis", .red),
            t(.pluginManager, "Plugins", "Extensions & add-ons", "puzzlepiece.extension", .indigo),
            t(.workspaceManager, "Workspaces", "Multi-archive", "square.grid.2x2", .gray),
        ])
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
        .help(label)
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
        .help("Browse, search and filter all \(emailCount) emails in your archive")
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
        .help("\(title) — \(subtitle)")
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
            Text("On-device by default · No account · No tracking")
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

    private func hubTile(_ tile: HubTile) -> some View {
        Button { onNavigate(tile.dest) } label: {
            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Image(systemName: tile.icon)
                    .font(.system(size: 22))
                    .foregroundColor(tile.color)
                    .frame(height: 26)

                Text(tile.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(tile.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(tile.color.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .strokeBorder(tile.color.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.title), \(tile.subtitle)")
        .help("\(tile.title) — \(tile.subtitle)")
    }
}

#if DEBUG
#Preview("Forensic Hub — workflow cards") {
    MainNavigationHubView(
        emailCount: 1026, filteredCount: 1026, persona: .forensic,
        onNavigate: { _ in }, onOpenArchive: {}, onNewImport: {},
        onSettings: {}
    )
    .frame(width: 900, height: 1300)
}
#endif
