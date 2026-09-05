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
        case .emailInbox:           return "Browse, search, and read your imported emails."
        case .attachmentGallery:    return "View and save every attachment from your archive."
        case .threadSummarizer:     return "Get an AI summary of long email conversations."
        case .duplicateManager:     return "Find and remove duplicate emails."

        case .emailAnalytics:       return "Charts of who, when, and how much was sent."
        case .topicClusters:        return "Group emails by topic automatically."
        case .timeline:             return "See email activity across days, weeks, months."
        case .communicationPatterns:return "Discover who talks to whom and how often."
        case .relationshipGraph:    return "Visualize the network of senders and recipients."
        case .executiveDashboard:   return "High-level summary for sharing with stakeholders."

        case .anomalyDetection:     return "Flag unusual sending patterns or timing."
        case .iocExtractor:         return "Extract suspicious IPs, URLs, and file hashes (IOCs)."
        case .phishingTriage:       return "Verdict queue for user-reported suspicious emails — auto-scored, one-click verdicts, IOC blocklist export."
        case .reviewDashboard:      return "Review progress, pace, and privilege-log completeness — the defensibility numbers."
        case .storyFile:            return "Your annotations as a cited findings document — the answer to 'how do you know this?'"
        case .workCenter:           return "Your work, the archive's intake register, and background jobs — the daily front door."
        case .smartAlerts:          return "Get notified when specific email patterns appear."
        case .keywordMonitor:       return "Watch for emails containing key terms."
        case .nearDuplicates:       return "Find emails that are almost identical."

        case .achMatrix:            return "Score competing hypotheses against email evidence — ranked by fewest inconsistencies, decided by you."
        case .factMatrix:           return "Map each contested fact to the emails that support or oppose it — both sides preserved."
        case .actionRegister:       return "Track corrective actions to their causes; closing requires a named human verifier with evidence."
        case .evidenceDesks:        return "Rate source reliability (Admiralty scale) and record contradictions and gaps — both sides kept, absence never treated as proof."
        case .reasoningStudio:      return "5W1H, Five Whys, fishbone and root-cause analysis over cited emails — cells answer or say UNKNOWN, and only you confirm a cause."
        case .eDiscovery:           return "Legal discovery workflow — review and produce documents."
        case .predictiveCoding:     return "AI-assisted document review that learns from your tagging."
        case .forensicReview:       return "Court-ready evidence coding and integrity verification."
        case .chainOfCustody:       return "Track every access, export, and modification."
        case .batesNumbering:       return "Add sequential legal tracking numbers to documents."
        case .gdprCompliance:       return "Detect personal data and generate GDPR reports."
        case .reviewBatches:        return "Organize emails into batches for systematic review."
        case .custodianPanel:       return "Manage the people responsible for the documents."

        case .reportBuilder:        return "Create custom investigation or compliance reports."
        case .batchOperations:      return "Tag, export, or process many emails at once."
        case .archiveComparison:    return "Compare two email archives side by side."
        case .investigationReport:  return "Auto-generated findings and timeline report."
        case .redaction:            return "Mark sensitive information for safe sharing."
        case .automationRules:      return "Auto-tag or organize emails based on rules."

        case .aiAssistant:          return "Ask questions about your emails in plain language."
        case .aiDigest:             return "Daily AI summary of important emails."
        case .smartAutoTagger:      return "AI categorizes your emails automatically."
        case .customExperts:        return "Configure AI personalities for specialized analysis."
        case .knowledgeGraphExplorer:return "Browse entities, topics, and connections found by AI."
        case .aiVisualizations:     return "AI-generated charts and visual summaries."
        case .backgroundFindings:   return "Findings discovered while you work, surfaced quietly."
        case .predictiveInsights:   return "Forecast trends and surface emerging patterns."
        case .pluginManager:        return "Extend mailin with optional analysis plugins."

        case .legalWorkspace:       return "Document review workspace for legal teams."
        case .itAdminDashboard:     return "Technical headers, authentication, and routing analysis."
        case .journalistWorkbench:  return "Source tracking, leads, and story-building tools."
        case .personalOrganizer:    return "Your simple email archive — clean and easy."
        case .generalExplorer:      return "All features visible — explore everything."
        case .personaHub:           return "Switch your workspace persona."

        case .workspaceManager:     return "Manage saved workspaces and archives."
        case .settings:             return "Preferences, account, privacy, and subscription."
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
        case .batesNumbering:   return "Bates Numbering"
        case .chainOfCustody:   return "Chain of Custody"
        case .custodian:        return "Custodian"
        case .eDiscovery:       return "eDiscovery"
        case .edrm:             return "EDRM"
        case .ioc:              return "IOC (Indicator of Compromise)"
        case .predictiveCoding: return "Predictive Coding / TAR"
        case .privilege:        return "Privilege (attorney-client)"
        case .redaction:        return "Redaction"
        case .spfDkimDmarc:     return "SPF / DKIM / DMARC"
        case .bm25:             return "BM25 Relevance Ranking"
        case .tar:              return "TAR (Technology-Assisted Review)"
        case .gdpr:             return "GDPR"
        case .audit:            return "Audit Trail"
        case .mime:             return "MIME"
        case .sentiment:        return "Sentiment Analysis"
        case .anomaly:          return "Anomaly Detection"
        case .privacyManifest:  return "Privacy Manifest"
        }
    }

    var definition: String {
        switch self {
        case .batesNumbering:
            return "Sequential numbers stamped on documents during legal production so each page has a unique reference. For example, ABC000001, ABC000002, ABC000003. Required by most courts for filings."
        case .chainOfCustody:
            return "A tamper-evident log of who accessed, modified, or exported each piece of evidence and when. Required for evidence to be admissible in court."
        case .custodian:
            return "The person whose emails are being reviewed — usually the original account holder. eDiscovery is typically organized around named custodians."
        case .eDiscovery:
            return "Electronic discovery — the process of identifying, collecting, and producing electronic documents for a lawsuit, investigation, or regulatory matter."
        case .edrm:
            return "The Electronic Discovery Reference Model — an industry-standard workflow: Identification → Preservation → Collection → Processing → Review → Analysis → Production."
        case .ioc:
            return "An indicator of compromise — a suspicious artifact (IP address, URL, file hash, domain) that suggests phishing, malware, or a breach attempt."
        case .predictiveCoding:
            return "AI that learns from sample emails you tag, then predicts which other emails are likely relevant. Lets you review thousands of emails in a fraction of the time."
        case .privilege:
            return "Communications between an attorney and their client that are legally protected from disclosure. Marking them privileged keeps them out of a production set."
        case .redaction:
            return "Hiding sensitive information (SSNs, medical info, trade secrets) in a document before sharing it. Different from deletion — the page structure is preserved."
        case .spfDkimDmarc:
            return "Three email authentication standards. They verify a message really came from the domain it claims, helping detect spoofing and phishing."
        case .bm25:
            return "A relevance ranking algorithm used by search engines. Scores emails by how strongly they match your search terms, not just whether they contain them."
        case .tar:
            return "Technology-Assisted Review — the same concept as predictive coding. Courts have widely accepted TAR as a defensible alternative to manual document review."
        case .gdpr:
            return "The EU General Data Protection Regulation. mailin can detect personal data (PII) in emails and generate a report listing what's there and where."
        case .audit:
            return "A timestamped log of every important action — opens, tags, exports, deletions — protected so it can't be silently edited. Used to prove evidence integrity."
        case .mime:
            return "Multipurpose Internet Mail Extensions — the standard structure of an email message including headers, body parts, and attachments."
        case .sentiment:
            return "An estimate of emotional tone (negative / neutral / positive) computed from the words used in an email."
        case .anomaly:
            return "An email or pattern that stands out from the norm — sent at odd hours, from an unusual sender, or with unexpected attachments. Worth a closer look."
        case .privacyManifest:
            return "An Apple-required file that declares what data your app reads and why. mailin's manifest lists zero tracking and minimal API usage."
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
