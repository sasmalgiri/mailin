//
//  PersonaManager.swift
//  mailin
//
//  Persona-based UI customization engine.
//  Each persona tailors sidebar visibility, toolbar actions, default density,
//  feature prominence, export ordering, accent colors, and AI sample queries.
//

import SwiftUI

@MainActor
class PersonaManager: ObservableObject {
    static let shared = PersonaManager()

    @AppStorage("selectedPersona") var selectedPersona: Persona = .general

    @Published var hasCompletedPersonaSelection = UserDefaults.standard.bool(forKey: "hasCompletedPersonaSelection")

    func switchPersona(to persona: Persona) {
        guard persona != selectedPersona else { return }
        selectedPersona = persona
        applyPersonaDefaults()
    }

    func completePersonaSelection() {
        hasCompletedPersonaSelection = true
        UserDefaults.standard.set(true, forKey: "hasCompletedPersonaSelection")
        applyPersonaDefaults()
    }

    // MARK: - Persona Definition

    enum Persona: String, CaseIterable, Codable {
        case forensic = "forensic"
        case legal = "legal"
        case itAdmin = "it_admin"
        case journalist = "journalist"
        case personal = "personal"
        case general = "general"

        var displayName: String {
            switch self {
            case .forensic: return "Forensic Investigator"
            case .legal: return "Legal / eDiscovery"
            case .itAdmin: return "IT Administrator"
            case .journalist: return "Journalist / Researcher"
            case .personal: return "Personal Use"
            case .general: return "Other / Just Exploring"
            }
        }

        var icon: String {
            switch self {
            case .forensic: return "shield.checkered"
            case .legal: return "building.columns"
            case .itAdmin: return "server.rack"
            case .journalist: return "newspaper"
            case .personal: return "person.crop.circle"
            case .general: return "ellipsis.circle"
            }
        }

        var tagline: String {
            switch self {
            case .forensic: return "Evidence integrity, chain of custody, court-ready exports"
            case .legal: return "Privilege review, keyword search, production sets"
            case .itAdmin: return "Technical headers, MIME analysis, server routing"
            case .journalist: return "Pattern discovery, timelines, contact networks"
            case .personal: return "Simple reading, search, and attachment recovery"
            case .general: return "All features available — customize later in Settings"
            }
        }

        var impactDescription: String {
            switch self {
            case .forensic: return "Shows: evidence tags, audit trail, hash verification, technical headers"
            case .legal: return "Shows: privilege filters, Bates numbering, production exports, review batches"
            case .itAdmin: return "Shows: MIME tree, SPF/DKIM analysis, routing headers, domain filters"
            case .journalist: return "Shows: analytics dashboard, reply patterns, sentiment filters, redaction"
            case .personal: return "Shows: clean layout, basic search and filters, attachment gallery"
            case .general: return "Shows: everything — you can toggle features on or off as needed"
            }
        }

        var accentColor: Color {
            switch self {
            case .forensic: return .orange
            case .legal: return .indigo
            case .itAdmin: return .teal
            case .journalist: return .purple
            case .personal: return .blue
            case .general: return .mint
            }
        }

        var color: Color { accentColor }

        var shortLabel: String {
            switch self {
            case .forensic: return "Forensic"
            case .legal: return "Legal"
            case .itAdmin: return "IT Admin"
            case .journalist: return "Journalist"
            case .personal: return "Personal"
            case .general: return "General"
            }
        }
    }

    // MARK: - Per-Persona Configuration

    struct PersonaConfig {
        let defaultDensity: String
        let showEmailPreviews: Bool
        let showForensicByDefault: Bool
        let enableAIByDefault: Bool
        let showAnalyticsProminent: Bool
        let showTechnicalHeaders: Bool
        let showQuickFilters: [QuickFilter]
        let sidebarSections: [SidebarSection]
        let exportOrder: [ExportFormat]
        let sampleAIQueries: [String]
        let emptyStateMessage: String
        let welcomeTitle: String
    }

    enum QuickFilter: String, CaseIterable {
        case sent = "Sent"
        case received = "Received"
        case attachments = "Attachments"
        case cleanup = "Cleanup"
        case flagged = "Flagged"
        case privileged = "Privileged"
        case unreviewed = "Unreviewed"
        case highPriority = "High Priority"
        case hasLinks = "Has Links"
        case largeEmails = "Large"
        // AI-powered smart filters
        case aiImportant = "Important"
        case aiSuspicious = "Suspicious"
        case aiNegative = "Negative"
        case aiNewsletter = "Newsletters"
    }

    enum SidebarSection: String, CaseIterable {
        case summary = "Summary"
        case dateRange = "Date Range"
        case senders = "Senders"
        case recipients = "Recipients"
        case labels = "Labels"
        case evidenceTags = "Evidence Tags"
        case replyFrequency = "Reply Frequency"
        case domains = "Domains"
    }

    enum ExportFormat: String {
        case plainText = "Plain Text"
        case csv = "CSV"
        case pdf = "PDF"
        case batesPDF = "Bates-Stamped PDF"
        case forensicReport = "Forensic Report"
        case redacted = "Redacted"
    }

    // MARK: - Config Lookup

    var config: PersonaConfig {
        Self.config(for: selectedPersona)
    }

    static func config(for persona: Persona) -> PersonaConfig {
        switch persona {
        case .forensic:
            return PersonaConfig(
                defaultDensity: "compact",
                showEmailPreviews: false,
                showForensicByDefault: true,
                enableAIByDefault: true,
                showAnalyticsProminent: false,
                showTechnicalHeaders: true,
                showQuickFilters: [.sent, .received, .attachments, .flagged, .unreviewed, .highPriority, .hasLinks, .aiImportant, .aiSuspicious, .aiNegative],
                sidebarSections: [.summary, .dateRange, .evidenceTags, .senders, .recipients, .domains],
                exportOrder: [.batesPDF, .forensicReport, .redacted, .csv, .plainText, .pdf],
                sampleAIQueries: [
                    "Identify suspicious emails with spoofing indicators",
                    "Find all emails containing PII (SSN, credit cards, addresses)",
                    "Timeline of communication between key parties",
                    "Detect anomalous sending patterns or time gaps",
                    "Summarize email chains related to the investigation",
                    "Which emails were sent outside business hours?",
                    "Find emails with deleted or modified attachments"
                ],
                emptyStateMessage: "Import an mbox or eml file to begin forensic analysis. All processing stays on-device.",
                welcomeTitle: "Forensic Workstation"
            )

        case .legal:
            return PersonaConfig(
                defaultDensity: "comfortable",
                showEmailPreviews: true,
                showForensicByDefault: false,
                enableAIByDefault: true,
                showAnalyticsProminent: false,
                showTechnicalHeaders: false,
                showQuickFilters: [.attachments, .flagged, .privileged, .unreviewed, .cleanup, .aiImportant, .aiSuspicious, .aiNewsletter],
                sidebarSections: [.summary, .dateRange, .senders, .recipients, .labels, .evidenceTags],
                exportOrder: [.batesPDF, .csv, .redacted, .forensicReport, .pdf, .plainText],
                sampleAIQueries: [
                    "Find all attorney-client privileged communications",
                    "Identify emails discussing contract terms or negotiations",
                    "List all emails with legal holds or compliance keywords",
                    "Summarize the dispute timeline between parties",
                    "Find emails referencing specific dollar amounts or dates",
                    "Which custodians communicated most frequently?",
                    "Identify responsive documents for production"
                ],
                emptyStateMessage: "Import email archives for review. Use evidence tags to code documents and export production sets.",
                welcomeTitle: "Document Review"
            )

        case .itAdmin:
            return PersonaConfig(
                defaultDensity: "compact",
                showEmailPreviews: false,
                showForensicByDefault: false,
                enableAIByDefault: true,
                showAnalyticsProminent: false,
                showTechnicalHeaders: true,
                showQuickFilters: [.sent, .received, .attachments, .largeEmails, .hasLinks, .highPriority, .aiImportant, .aiSuspicious, .aiNewsletter],
                sidebarSections: [.summary, .dateRange, .senders, .recipients, .domains, .labels],
                exportOrder: [.csv, .plainText, .pdf, .batesPDF, .forensicReport, .redacted],
                sampleAIQueries: [
                    "Show email routing paths and relay servers",
                    "Find emails with authentication failures (SPF/DKIM/DMARC)",
                    "Identify the most common sending domains and servers",
                    "Detect emails with unusual MIME structures",
                    "List all unique IP addresses in received headers",
                    "Find bounce messages and delivery failures",
                    "Which emails have the largest attachments?"
                ],
                emptyStateMessage: "Import mbox or eml archives for technical analysis. View headers, MIME structure, and server routing.",
                welcomeTitle: "Email Technical Analysis"
            )

        case .journalist:
            return PersonaConfig(
                defaultDensity: "comfortable",
                showEmailPreviews: true,
                showForensicByDefault: false,
                enableAIByDefault: true,
                showAnalyticsProminent: true,
                showTechnicalHeaders: false,
                showQuickFilters: [.sent, .received, .attachments, .largeEmails, .aiImportant, .aiNegative, .aiNewsletter],
                sidebarSections: [.summary, .dateRange, .senders, .recipients, .labels, .replyFrequency],
                exportOrder: [.plainText, .csv, .pdf, .redacted, .batesPDF, .forensicReport],
                sampleAIQueries: [
                    "What are the main topics discussed in these emails?",
                    "Identify key decision makers and their communication patterns",
                    "Find emails that mention specific dates, events, or deadlines",
                    "Who are the most connected people in this archive?",
                    "Detect contradictions between what different people said",
                    "Build a timeline of events from these emails",
                    "Find emails with emotional or urgent language"
                ],
                emptyStateMessage: "Import email archives to discover patterns, connections, and stories. AI-powered analysis helps you find what matters.",
                welcomeTitle: "Email Investigation"
            )

        case .personal:
            return PersonaConfig(
                defaultDensity: "spacious",
                showEmailPreviews: true,
                showForensicByDefault: false,
                enableAIByDefault: false,
                showAnalyticsProminent: false,
                showTechnicalHeaders: false,
                showQuickFilters: [.sent, .received, .attachments, .aiImportant, .aiNewsletter],
                sidebarSections: [.summary, .dateRange, .senders, .labels, .replyFrequency],
                exportOrder: [.pdf, .plainText, .csv, .redacted, .batesPDF, .forensicReport],
                sampleAIQueries: [
                    "Summarize my emails from the last month",
                    "Find emails from a specific person",
                    "What are the most common topics in my inbox?",
                    "Show me emails with photos or documents attached",
                    "Who emails me the most?",
                    "Find important emails I might have missed"
                ],
                emptyStateMessage: "Open an mbox or eml file to browse your old emails, search messages, and save attachments.",
                welcomeTitle: "Email Archive"
            )

        case .general:
            return PersonaConfig(
                defaultDensity: "comfortable",
                showEmailPreviews: true,
                showForensicByDefault: false,
                enableAIByDefault: true,
                showAnalyticsProminent: true,
                showTechnicalHeaders: false,
                showQuickFilters: [.sent, .received, .attachments, .flagged, .cleanup, .aiImportant, .aiSuspicious, .aiNegative, .aiNewsletter],
                sidebarSections: [.summary, .dateRange, .senders, .recipients, .labels, .replyFrequency],
                exportOrder: [.pdf, .csv, .plainText, .batesPDF, .forensicReport, .redacted],
                sampleAIQueries: [
                    "Summarize the most important emails",
                    "What are the main topics discussed?",
                    "Who are the most frequent senders?",
                    "Find emails with attachments",
                    "Show me the communication timeline",
                    "Are there any urgent or time-sensitive emails?"
                ],
                emptyStateMessage: "Import an mbox or eml file to get started. Search, filter, analyze, and export your emails.",
                welcomeTitle: "Email Explorer"
            )
        }
    }

    // MARK: - Convenience Accessors

    func showSection(_ section: SidebarSection) -> Bool {
        config.sidebarSections.contains(section)
    }

    func showQuickFilter(_ filter: QuickFilter) -> Bool {
        config.showQuickFilters.contains(filter)
    }

    // MARK: - Apply Defaults on Persona Change

    private func applyPersonaDefaults() {
        let cfg = config
        UserDefaults.standard.set(cfg.defaultDensity, forKey: "emailListDensity")
        UserDefaults.standard.set(cfg.showEmailPreviews, forKey: "showEmailPreviews")
        UserDefaults.standard.set(cfg.enableAIByDefault, forKey: "enableAIFeatures")
        UserDefaults.standard.set(cfg.showForensicByDefault, forKey: "forensicModeEnabled")

        switch selectedPersona {
        case .forensic:
            UserDefaults.standard.set(true, forKey: "showAdvancedFeatures")
            UserDefaults.standard.set(true, forKey: "aiTagsApplied")
        case .legal:
            UserDefaults.standard.set(true, forKey: "showAdvancedFeatures")
            UserDefaults.standard.set(false, forKey: "aiTagsApplied")
        case .itAdmin:
            UserDefaults.standard.set(false, forKey: "showAdvancedFeatures")
            UserDefaults.standard.set(true, forKey: "aiTagsApplied")
        case .journalist:
            UserDefaults.standard.set(false, forKey: "showAdvancedFeatures")
            UserDefaults.standard.set(true, forKey: "aiTagsApplied")
        case .personal:
            UserDefaults.standard.set(false, forKey: "showAdvancedFeatures")
            UserDefaults.standard.set(false, forKey: "aiTagsApplied")
        case .general:
            UserDefaults.standard.set(false, forKey: "showAdvancedFeatures")
            UserDefaults.standard.set(false, forKey: "aiTagsApplied")
        }

        UserDefaults.standard.set(false, forKey: "personaFiltersInitialized")
    }
}
