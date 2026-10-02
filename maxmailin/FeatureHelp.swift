@testable import ArchiveCore
//
//  FeatureHelp.swift
//  mailin
//
//  Lightweight, always-visible help: one-line captions for every hub
//  destination and a plain-language glossary of jargon. Designed so help
//  is available without requiring hover (which doesn't work on touch).
//

import SwiftUI

// MARK: - Per-Destination Caption

extension HubDestination {
    /// Short, plain-language description suitable for tooltips, accessibility
    /// hints, and inline captions under feature tiles.
    var caption: String {
        switch self {
        case .emailInbox:           return String(localized: "Browse, search, and read your imported emails.")
        case .attachmentGallery:    return String(localized: "View and save every attachment from your archive.")
        case .threadSummarizer:     return String(localized: "Get an AI summary of long email conversations.")
        case .duplicateManager:     return String(localized: "Find and remove duplicate emails.")

        case .emailAnalytics:       return String(localized: "Charts of who, when, and how much was sent.")
        case .topicClusters:        return String(localized: "Group emails by topic automatically.")
        case .timeline:             return String(localized: "See email activity across days, weeks, months.")
        case .communicationPatterns:return String(localized: "Discover who talks to whom and how often.")
        case .relationshipGraph:    return String(localized: "Visualize the network of senders and recipients.")
        case .executiveDashboard:   return String(localized: "High-level summary for sharing with stakeholders.")

        case .anomalyDetection:     return String(localized: "Flag unusual sending patterns or timing.")
        case .iocExtractor:         return String(localized: "Extract suspicious IPs, URLs, and file hashes (IOCs).")
        case .phishingTriage:       return String(localized: "Verdict queue for user-reported suspicious emails — auto-scored, one-click verdicts, IOC blocklist export.")
        case .reviewDashboard:      return String(localized: "Review progress, pace, and privilege-log completeness — the defensibility numbers.")
        case .storyFile:            return String(localized: "Your annotations as a cited findings document — the answer to 'how do you know this?'")
        case .workCenter:           return String(localized: "Your work, the archive's intake register, and background jobs — the daily front door.")
        case .smartAlerts:          return String(localized: "Get notified when specific email patterns appear.")
        case .keywordMonitor:       return String(localized: "Watch for emails containing key terms.")
        case .nearDuplicates:       return String(localized: "Find emails that are almost identical.")

        case .achMatrix:            return String(localized: "Score competing hypotheses against email evidence — ranked by fewest inconsistencies, decided by you.")
        case .factMatrix:           return String(localized: "Map each contested fact to the emails that support or oppose it — both sides preserved.")
        case .actionRegister:       return String(localized: "Track corrective actions to their causes; closing requires a named human verifier with evidence.")
        case .evidenceDesks:        return String(localized: "Rate source reliability (Admiralty scale) and record contradictions and gaps — both sides kept, absence never treated as proof.")
        case .reasoningStudio:      return String(localized: "5W1H, Five Whys, fishbone and root-cause analysis over cited emails — cells answer or say UNKNOWN, and only you confirm a cause.")
        case .eDiscovery:           return String(localized: "Legal discovery workflow — review and produce documents.")
        case .predictiveCoding:     return String(localized: "AI-assisted document review that learns from your tagging.")
        case .forensicReview:       return String(localized: "Court-ready evidence coding and integrity verification.")
        case .chainOfCustody:       return String(localized: "Track every access, export, and modification.")
        case .batesNumbering:       return String(localized: "Add sequential legal tracking numbers to documents.")
        case .gdprCompliance:       return String(localized: "Detect personal data and generate GDPR reports.")
        case .reviewBatches:        return String(localized: "Organize emails into batches for systematic review.")
        case .custodianPanel:       return String(localized: "Manage the people responsible for the documents.")

        case .reportBuilder:        return String(localized: "Create custom investigation or compliance reports.")
        case .batchOperations:      return String(localized: "Tag, export, or process many emails at once.")
        case .archiveComparison:    return String(localized: "Compare two email archives side by side.")
        case .investigationReport:  return String(localized: "Auto-generated findings and timeline report.")
        case .redaction:            return String(localized: "Mark sensitive information for safe sharing.")
        case .automationRules:      return String(localized: "Auto-tag or organize emails based on rules.")

        case .aiAssistant:          return String(localized: "Ask questions about your emails in plain language.")
        case .aiDigest:             return String(localized: "Daily AI summary of important emails.")
        case .smartAutoTagger:      return String(localized: "AI categorizes your emails automatically.")
        case .customExperts:        return String(localized: "Configure AI personalities for specialized analysis.")
        case .knowledgeGraphExplorer:return String(localized: "Browse entities, topics, and connections found by AI.")
        case .aiVisualizations:     return String(localized: "AI-generated charts and visual summaries.")
        case .backgroundFindings:   return String(localized: "Findings discovered while you work, surfaced quietly.")
        case .predictiveInsights:   return String(localized: "Forecast trends and surface emerging patterns.")
        case .pluginManager:        return String(localized: "Extend mailin with optional analysis plugins.")

        case .legalWorkspace:       return String(localized: "Document review workspace for legal teams.")
        case .itAdminDashboard:     return String(localized: "Technical headers, authentication, and routing analysis.")
        case .journalistWorkbench:  return String(localized: "Source tracking, leads, and story-building tools.")
        case .personalOrganizer:    return String(localized: "Your simple email archive — clean and easy.")
        case .generalExplorer:      return String(localized: "All features visible — explore everything.")
        case .personaHub:           return String(localized: "Switch your workspace persona.")

        case .workspaceManager:     return String(localized: "Manage saved workspaces and archives.")
        case .settings:             return String(localized: "Preferences, account, privacy, and subscription.")
        }
    }
}

// MARK: - Glossary

/// Jargon used across the app, with plain-language definitions.
/// Surfaced via `GlossaryView` (from Settings) and inline `GlossaryButton`
/// next to specialist terms.
enum GlossaryTerm: String, CaseIterable, Identifiable {
    case batesNumbering
    case chainOfCustody
    case custodian
    case eDiscovery
    case edrm
    case ioc
    case predictiveCoding
    case privilege
    case redaction
    case spfDkimDmarc
    case bm25
    case tar
    case gdpr
    case audit
    case mime
    case sentiment
    case anomaly
    case privacyManifest

    var id: String { rawValue }

    var term: String {
        switch self {
        case .batesNumbering:   return String(localized: "Bates Numbering")
        case .chainOfCustody:   return String(localized: "Chain of Custody")
        case .custodian:        return String(localized: "Custodian")
        case .eDiscovery:       return "eDiscovery"
        case .edrm:             return "EDRM"
        case .ioc:              return String(localized: "IOC (Indicator of Compromise)")
        case .predictiveCoding: return String(localized: "Predictive Coding / TAR")
        case .privilege:        return String(localized: "Privilege (attorney-client)")
        case .redaction:        return String(localized: "Redaction")
        case .spfDkimDmarc:     return String(localized: "SPF / DKIM / DMARC")
        case .bm25:             return String(localized: "BM25 Relevance Ranking")
        case .tar:              return String(localized: "TAR (Technology-Assisted Review)")
        case .gdpr:             return "GDPR"
        case .audit:            return String(localized: "Audit Trail")
        case .mime:             return "MIME"
        case .sentiment:        return String(localized: "Sentiment Analysis")
        case .anomaly:          return String(localized: "Anomaly Detection")
        case .privacyManifest:  return String(localized: "Privacy Manifest")
        }
    }

    var definition: String {
        switch self {
        case .batesNumbering:
            return String(localized: "Sequential numbers stamped on documents during legal production so each page has a unique reference. For example, ABC000001, ABC000002, ABC000003. Required by most courts for filings.")
        case .chainOfCustody:
            return String(localized: "A tamper-evident log of who accessed, modified, or exported each piece of evidence and when. Required for evidence to be admissible in court.")
        case .custodian:
            return String(localized: "The person whose emails are being reviewed — usually the original account holder. eDiscovery is typically organized around named custodians.")
        case .eDiscovery:
            return String(localized: "Electronic discovery — the process of identifying, collecting, and producing electronic documents for a lawsuit, investigation, or regulatory matter.")
        case .edrm:
            return String(localized: "The Electronic Discovery Reference Model — an industry-standard workflow: Identification → Preservation → Collection → Processing → Review → Analysis → Production.")
        case .ioc:
            return String(localized: "An indicator of compromise — a suspicious artifact (IP address, URL, file hash, domain) that suggests phishing, malware, or a breach attempt.")
        case .predictiveCoding:
            return String(localized: "AI that learns from sample emails you tag, then predicts which other emails are likely relevant. Lets you review thousands of emails in a fraction of the time.")
        case .privilege:
            return String(localized: "Communications between an attorney and their client that are legally protected from disclosure. Marking them privileged keeps them out of a production set.")
        case .redaction:
            return String(localized: "Hiding sensitive information (SSNs, medical info, trade secrets) in a document before sharing it. Different from deletion — the page structure is preserved.")
        case .spfDkimDmarc:
            return String(localized: "Three email authentication standards. They verify a message really came from the domain it claims, helping detect spoofing and phishing.")
        case .bm25:
            return String(localized: "A relevance ranking algorithm used by search engines. Scores emails by how strongly they match your search terms, not just whether they contain them.")
        case .tar:
            return String(localized: "Technology-Assisted Review — the same concept as predictive coding. Courts have widely accepted TAR as a defensible alternative to manual document review.")
        case .gdpr:
            return String(localized: "The EU General Data Protection Regulation. mailin can detect personal data (PII) in emails and generate a report listing what's there and where.")
        case .audit:
            return String(localized: "A timestamped log of every important action — opens, tags, exports, deletions — protected so it can't be silently edited. Used to prove evidence integrity.")
        case .mime:
            return String(localized: "Multipurpose Internet Mail Extensions — the standard structure of an email message including headers, body parts, and attachments.")
        case .sentiment:
            return String(localized: "An estimate of emotional tone (negative / neutral / positive) computed from the words used in an email.")
        case .anomaly:
            return String(localized: "An email or pattern that stands out from the norm — sent at odd hours, from an unusual sender, or with unexpected attachments. Worth a closer look.")
        case .privacyManifest:
            return String(localized: "An Apple-required file that declares what data your app reads and why. mailin's manifest lists zero tracking and minimal API usage.")
        }
    }
}

// MARK: - Glossary View

struct GlossaryView: View {
    @State private var search: String = ""

    private var filtered: [GlossaryTerm] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return GlossaryTerm.allCases }
        let lower = trimmed.lowercased()
        return GlossaryTerm.allCases.filter {
            $0.term.lowercased().contains(lower) || $0.definition.lowercased().contains(lower)
        }
    }

    var body: some View {
        List {
            Section {
                Text("Plain-language definitions for the legal, forensic, and technical terms used in mailin. Tap any entry to expand.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(filtered) { entry in
                DisclosureGroup {
                    Text(entry.definition)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .padding(.vertical, 4)
                } label: {
                    Label(entry.term, systemImage: "book.closed")
                        .font(.headline)
                }
            }
        }
        .searchable(text: $search, prompt: "Search glossary")
        .navigationTitle("Glossary")
    }
}

// MARK: - Inline Help Button

/// Small "(i)" button that pops up the caption for a destination and a
/// "Learn more" link to the glossary. Use next to specialist controls.
struct FeatureHelpButton: View {
    let title: String
    let caption: String
    let glossaryTerm: GlossaryTerm?

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.callout)
                    .foregroundColor(.primary)
                if let term = glossaryTerm {
                    Divider()
                    Text(term.term)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(term.definition)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: 320)
        }
    }
}

#Preview("Glossary") {
    NavigationStack {
        GlossaryView()
    }
}
