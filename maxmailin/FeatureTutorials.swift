//
//  FeatureTutorials.swift
//  mailin
//
//  Tutorial content definitions for all features.
//

import SwiftUI

// swiftlint:disable type_body_length file_length
extension FeatureTutorial {

    // MARK: - Forensic Review

    static let forensicReview = FeatureTutorial(
        title: "How to Use Forensic Review",
        icon: "shield.checkered",
        overview: "Forensic Review is your evidence coding workspace. Tag emails as relevant, privileged, or suspicious, annotate findings, verify email integrity with SHA-256 hashes, and build a tamper-evident audit trail for legal proceedings.",
        quickStart: "Select emails from the list, tag them using the evidence buttons (Relevant, Privileged, Flagged), and add annotations. Every action is logged in the forensic audit trail with HMAC-chained integrity verification.",
        steps: [
            TutorialStep(title: "Select Emails", icon: "envelope", color: .blue,
                what: "Browse and select emails to review.",
                how: "Click emails in the left panel to select them. Use the search bar to filter by keywords, sender, or date. Selected emails appear in the detail pane on the right.",
                tip: "Hold Shift to select multiple emails for bulk tagging."),
            TutorialStep(title: "Tag Evidence", icon: "tag.fill", color: .green,
                what: "Classify emails by their evidentiary value.",
                how: "Use the tag buttons to mark emails as Relevant, Privileged, Irrelevant, Flagged, or Suspicious. Tags are color-coded and tracked with timestamps for reviewer statistics.",
                tip: "Use 'Flagged' for emails that need a second reviewer's opinion."),
            TutorialStep(title: "Annotate", icon: "note.text", color: .orange,
                what: "Add notes explaining why an email matters.",
                how: "Click the annotation field below the email detail to add your analysis notes. Annotations are stored with your examiner name and timestamp.",
                tip: "Be specific — annotations may be referenced in court proceedings."),
            TutorialStep(title: "Verify Integrity", icon: "checkmark.shield", color: .purple,
                what: "Confirm emails haven't been tampered with.",
                how: "The integrity panel shows SHA-256 hash verification status. Green means the email matches its original hash. Red means potential tampering detected.",
                tip: "Run integrity checks before and after review sessions to maintain chain of custody."),
            TutorialStep(title: "Export Evidence", icon: "square.and.arrow.up", color: .teal,
                what: "Generate reports and export tagged evidence.",
                how: "Use the export options to generate Concordance DAT load files, CSV reports, privilege logs, or a complete audit trail. All exports include Bates numbers if configured.",
                tip: "Export the audit trail separately — it provides cryptographic proof of your review process.")
        ],
        tips: [
            TutorialTip(icon: "lock.shield", text: "Every tag, annotation, and action is recorded in an HMAC-chained audit log that detects tampering."),
            TutorialTip(icon: "person.badge.shield.checkmark", text: "Set your examiner name in settings — it appears on all audit entries."),
            TutorialTip(icon: "doc.text.magnifyingglass", text: "Use the header analysis tab to inspect raw email headers and routing information."),
            TutorialTip(icon: "exclamationmark.triangle", text: "Spoofing indicators are automatically detected and shown with risk scores.")
        ]
    )

    // MARK: - Legal Review Workspace

    static let legalReview = FeatureTutorial(
        title: "How to Use Legal Review",
        icon: "briefcase.fill",
        overview: "The Legal Review Workspace is designed for privilege review and document coding in litigation. Code emails for attorney-client privilege, work product, and responsiveness. Manage review batches, track coding progress, and generate privilege logs.",
        quickStart: "Open a document set, code each email for privilege and responsiveness using the coding pane on the right, then generate a privilege log for production. The system auto-detects likely privileged communications.",
        steps: [
            TutorialStep(title: "Load Documents", icon: "doc.on.doc", color: .indigo,
                what: "Select the emails to review for privilege.",
                how: "The left panel shows your email collection. Use filters to narrow by date, sender, or domain. Click an email to open it in the detail pane.",
                tip: "Start with auto-detected privilege flags — they're marked with a shield icon."),
            TutorialStep(title: "Code for Privilege", icon: "shield.lefthalf.filled", color: .purple,
                what: "Mark emails as privileged, responsive, or non-responsive.",
                how: "Use the privilege coding buttons in the right pane. Options include Attorney-Client Privilege, Work Product, Confidential, and Responsive/Non-Responsive. Add privilege descriptions for the log.",
                tip: "The AI suggestion panel can recommend privilege codes based on email content and sender domains."),
            TutorialStep(title: "Cross-Reference", icon: "link", color: .blue,
                what: "Check related communications for consistency.",
                how: "The cross-reference panel shows thread context and related emails from the same parties. Ensure privilege designations are consistent across a thread.",
                tip: "If one email in a thread is privileged, check if the entire thread needs the same designation."),
            TutorialStep(title: "Generate Privilege Log", icon: "doc.text", color: .green,
                what: "Create a privilege log for opposing counsel.",
                how: "Click 'Generate Privilege Log' to export a CSV listing all withheld documents with Bates numbers, privilege basis, and descriptions — ready for court filing.",
                tip: "Review the log before submitting — ensure every withheld document has a valid privilege basis.")
        ],
        tips: [
            TutorialTip(icon: "brain", text: "AI suggestions use NLP to detect legal terminology and attorney-domain patterns."),
            TutorialTip(icon: "number", text: "Bates numbers are auto-assigned — configure the prefix in Bates Numbering settings."),
            TutorialTip(icon: "chart.bar", text: "The dashboard tab shows review progress, coding speed, and distribution of privilege codes."),
            TutorialTip(icon: "clock", text: "Your average time per document is tracked — useful for estimating review completion.")
        ]
    )

    // MARK: - IT Admin Analysis

    static let itAdmin = FeatureTutorial(
        title: "How to Use IT Admin Analysis",
        icon: "server.rack",
        overview: "IT Admin Analysis provides security-focused email header inspection, threat scoring, phishing detection, and domain intelligence. Analyze email authentication (SPF/DKIM/DMARC), detect spoofing, and investigate suspicious patterns across your email archive.",
        quickStart: "Select an email to see its full header analysis, authentication results, and threat score. Use the tabs to switch between Header Analysis, Threat Dashboard, Domain Intelligence, and Anomalies.",
        steps: [
            TutorialStep(title: "Inspect Headers", icon: "doc.text.magnifyingglass", color: .blue,
                what: "View raw email headers and routing information.",
                how: "The Header Analysis tab shows every header field, the Received chain (routing hops), and authentication results. Failed SPF/DKIM/DMARC checks are highlighted in red.",
                tip: "Check the Received chain to trace the actual path an email took — mismatches indicate potential spoofing."),
            TutorialStep(title: "Check Threat Score", icon: "exclamationmark.shield", color: .red,
                what: "See the composite threat score for each email.",
                how: "The Threat Dashboard shows a 0-100 risk score combining phishing indicators, authentication failures, anomaly signals, and content analysis. High-risk emails are flagged automatically.",
                tip: "Scores above 70 indicate high risk — investigate these emails immediately."),
            TutorialStep(title: "Analyze Domains", icon: "globe", color: .purple,
                what: "Investigate sender and link domains.",
                how: "The Domain Intelligence tab shows all domains in your archive with connection counts, first/last seen dates, and risk indicators. Click a domain to see all emails from it.",
                tip: "Look for newly-seen domains with high email volume — they may indicate a phishing campaign."),
            TutorialStep(title: "Review Anomalies", icon: "waveform.badge.exclamationmark", color: .orange,
                what: "Find statistical outliers and unusual patterns.",
                how: "The Anomalies tab runs the anomaly detection engine to find frequency spikes, unusual sending hours, tone shifts, and new domain appearances. Each anomaly shows affected emails.",
                tip: "Combine anomaly results with threat scores for the most comprehensive security picture.")
        ],
        tips: [
            TutorialTip(icon: "checkmark.shield", text: "Green shield = SPF/DKIM/DMARC all pass. Red = one or more failed. Gray = no results available."),
            TutorialTip(icon: "arrow.triangle.branch", text: "The Received chain reads bottom-to-top — the bottom entry is the originating server."),
            TutorialTip(icon: "magnifyingglass", text: "Use the search bar to filter by specific header fields or values."),
            TutorialTip(icon: "square.and.arrow.up", text: "Export security findings as CSV for your incident response documentation.")
        ]
    )

    // MARK: - Journalist Investigation

    static let journalist = FeatureTutorial(
        title: "How to Use Investigation Workbench",
        icon: "newspaper.fill",
        overview: "The Investigation Workbench helps journalists analyze email archives for newsworthy patterns. Track sources, assess credibility, discover connections between contacts, extract quotes, and build investigation timelines with evidence bookmarking.",
        quickStart: "Start with the Overview tab to see key metrics, then use Source Analysis to evaluate contacts, Topic Discovery for story threads, and the Timeline to build a chronological narrative.",
        steps: [
            TutorialStep(title: "Analyze Sources", icon: "person.2", color: .blue,
                what: "Evaluate source reliability and communication patterns.",
                how: "The Sources tab ranks contacts by email volume, sentiment, and topic diversity. Click a source to see their full communication history, average tone, and which topics they discuss.",
                tip: "Sources with consistent sentiment and diverse topics tend to be more reliable."),
            TutorialStep(title: "Discover Topics", icon: "text.magnifyingglass", color: .purple,
                what: "Find story threads using NLP topic extraction.",
                how: "The Topics tab uses TF-IDF analysis to surface the most significant themes in the archive. Click a topic to see all related emails ranked by relevance.",
                tip: "Look for topics that appear suddenly or spike in frequency — they often indicate breaking developments."),
            TutorialStep(title: "Track Sentiment", icon: "face.smiling", color: .green,
                what: "Monitor how tone changes over time.",
                how: "The Sentiment tab shows NLP-based sentiment analysis across your archive. View per-contact sentiment trends and identify moments where communication tone shifts dramatically.",
                tip: "Sudden negative sentiment shifts in a thread may indicate a cover-up or conflict worth investigating."),
            TutorialStep(title: "Bookmark Evidence", icon: "bookmark.fill", color: .orange,
                what: "Save key emails for your story.",
                how: "Bookmark important emails to build your evidence collection. Bookmarked emails can be exported as a PDF investigation report with timeline and annotations.",
                tip: "Add notes to bookmarks explaining why each email matters to your story."),
            TutorialStep(title: "Generate Report", icon: "doc.richtext", color: .teal,
                what: "Export a complete investigation report.",
                how: "Use the Export button to generate a PDF report including your bookmarked evidence, timeline, source analysis, and key findings — ready for editorial review.",
                tip: "Include the sentiment trend chart — it visually demonstrates how a story evolved over time.")
        ],
        tips: [
            TutorialTip(icon: "quote.opening", text: "The quote finder extracts direct quotes from emails — useful for sourcing."),
            TutorialTip(icon: "link", text: "Use the connection finder to discover hidden links between seemingly unrelated sources."),
            TutorialTip(icon: "clock", text: "The timeline view shows email density over time — spikes often correlate with newsworthy events."),
            TutorialTip(icon: "shield.checkered", text: "Always verify source identity using header authentication before publishing.")
        ]
    )

    // MARK: - Personal Email Organizer

    static let personal = FeatureTutorial(
        title: "How to Use Email Organizer",
        icon: "tray.2.fill",
        overview: "The Personal Email Organizer automatically categorizes your emails using NLP, scores priority, provides contact insights, and helps you clean up your archive. It turns a messy inbox into organized, actionable information.",
        quickStart: "The Overview tab shows your inbox summary with top contacts and categories. Use the Categories tab to browse by type (personal, transactional, newsletters), and check Action Required for urgent items.",
        steps: [
            TutorialStep(title: "View Categories", icon: "folder.fill", color: .blue,
                what: "See emails auto-sorted by NLP classification.",
                how: "The Categories tab shows emails grouped as Personal, Transactional, Newsletter, Promotional, or Automated. Click a category to see all emails in it. The system uses NLP keyword analysis for classification.",
                tip: "Newsletters and Promotional categories are good candidates for bulk cleanup."),
            TutorialStep(title: "Check Priorities", icon: "exclamationmark.circle", color: .red,
                what: "Find emails that need your attention.",
                how: "The Action Required section uses NLP priority scoring to surface urgent emails. Items are ranked by a composite score considering urgency language, sender importance, and recency.",
                tip: "Emails with questions directed at you score highest — check these first."),
            TutorialStep(title: "Contact Insights", icon: "person.crop.circle", color: .green,
                what: "Understand your communication patterns.",
                how: "The Contacts tab shows your most frequent contacts with email counts, average sentiment, and topics discussed. Click a contact to see their full history.",
                tip: "Contacts with declining sentiment may need a personal check-in."),
            TutorialStep(title: "Clean Up", icon: "trash", color: .orange,
                what: "Identify emails safe to archive or delete.",
                how: "The Cleanup tab highlights old newsletters, automated notifications, and low-priority emails that can be safely archived. Review the suggestions and batch-select for cleanup.",
                tip: "Sort by date to find the oldest automated emails first — they're usually safe to remove.")
        ],
        tips: [
            TutorialTip(icon: "magnifyingglass", text: "Use the search bar to find specific emails across all categories."),
            TutorialTip(icon: "chart.pie", text: "The Overview chart shows your email category distribution at a glance."),
            TutorialTip(icon: "bell", text: "Priority scoring considers sender frequency — regular contacts get a boost."),
            TutorialTip(icon: "arrow.clockwise", text: "Re-run classification after importing new emails to keep categories current.")
        ]
    )

    // MARK: - General Analysis

    static let general = FeatureTutorial(
        title: "How to Use General Analysis",
        icon: "chart.bar.xaxis",
        overview: "General Analysis is your starting point for exploring an email archive. It provides quick statistics, search, and discovery tools to help you understand what's in your data before diving into specialized analysis views.",
        quickStart: "Check the quick stats at the top for an archive overview (email count, date range, top senders). Use the search bar to find specific content, and explore the feature cards to access specialized tools.",
        steps: [
            TutorialStep(title: "Review Stats", icon: "number", color: .blue,
                what: "Get an instant overview of your archive.",
                how: "The stats row shows total emails, unique senders, date range, and domain count. These numbers update as you import new data.",
                tip: "A high domain count relative to email count may indicate a diverse or spam-heavy archive."),
            TutorialStep(title: "Search Content", icon: "magnifyingglass", color: .purple,
                what: "Find emails by keywords or phrases.",
                how: "Type in the search bar to search across all email content, headers, and metadata. Results are ranked by relevance using BM25 scoring.",
                tip: "Use quotes for exact phrases: \"meeting agenda\" finds that exact phrase."),
            TutorialStep(title: "Explore Features", icon: "square.grid.2x2", color: .green,
                what: "Discover specialized analysis tools.",
                how: "The feature cards show available analysis tools based on your persona. Click any card to navigate to that feature. Each card shows a brief description of what it offers.",
                tip: "Start with Email Analytics for comprehensive statistics, or Anomaly Detection if you're investigating suspicious activity.")
        ],
        tips: [
            TutorialTip(icon: "person.crop.circle", text: "Switch personas from the home screen to see different feature sets tailored to your role."),
            TutorialTip(icon: "questionmark.circle", text: "Every feature has a ? button — click it anytime for a guide on that specific tool."),
            TutorialTip(icon: "square.and.arrow.down", text: "Import more email files (MBOX, EML, PST) from the Email Inbox to expand your archive.")
        ]
    )

    // MARK: - Email Analytics

    static let emailAnalytics = FeatureTutorial(
        title: "How to Use Email Analytics",
        icon: "chart.bar.fill",
        overview: "Email Analytics provides comprehensive statistical analysis of your email archive. View sender/recipient distributions, volume trends over time, communication patterns, and content metrics to understand the full picture of your email data.",
        quickStart: "Browse the tabs: Volume shows email counts over time, Senders/Recipients show top contacts, Content shows word counts and language stats. Use the date filter to focus on specific periods.",
        steps: [
            TutorialStep(title: "Volume Trends", icon: "chart.line.uptrend.xyaxis", color: .blue,
                what: "See how email volume changes over time.",
                how: "The Volume tab shows a timeline chart of emails per day/week/month. Spikes and dips are easy to spot. Use the date range picker to zoom into specific periods.",
                tip: "Look for volume spikes — they often correspond to major events, projects, or incidents."),
            TutorialStep(title: "Sender Analysis", icon: "person.fill", color: .green,
                what: "Identify top senders and their patterns.",
                how: "The Senders tab ranks all email senders by volume. Click a sender to see their email timeline, average message length, and most common subjects.",
                tip: "The top 10 senders usually account for 80%+ of an archive — focus your analysis there."),
            TutorialStep(title: "Content Metrics", icon: "doc.text", color: .purple,
                what: "Analyze email content characteristics.",
                how: "The Content tab shows average word count, attachment rates, language distribution, and reply chain depths. These metrics help characterize the nature of the archive.",
                tip: "High reply chain depths suggest active discussions — great for finding decision-making trails."),
            TutorialStep(title: "Export Charts", icon: "square.and.arrow.up", color: .orange,
                what: "Save analytics for reports.",
                how: "Use the export button to save charts and statistics as images or CSV data for inclusion in reports and presentations.",
                tip: "CSV exports are useful for creating custom visualizations in spreadsheet tools.")
        ],
        tips: [
            TutorialTip(icon: "calendar", text: "Use date filters to compare different time periods side by side."),
            TutorialTip(icon: "globe", text: "Domain analysis reveals which organizations are most represented in the archive."),
            TutorialTip(icon: "arrow.left.arrow.right", text: "Sent vs. received ratios indicate whether a custodian was primarily a sender or recipient.")
        ]
    )

    // MARK: - Anomaly Detection

    static let anomalyDetection = FeatureTutorial(
        title: "How to Use Anomaly Detection",
        icon: "waveform.badge.exclamationmark",
        overview: "The Anomaly Detection engine uses statistical analysis to find unusual patterns in your email archive. It detects frequency spikes, unusual sending hours, tone shifts, new domain appearances, and other deviations from normal patterns.",
        quickStart: "Click \"Run Detection\" to scan your archive. Results appear grouped by type (frequency, timing, tone, domain) with severity levels. Click any anomaly to see the affected emails.",
        steps: [
            TutorialStep(title: "Run Detection", icon: "play.fill", color: .blue,
                what: "Scan the archive for anomalies.",
                how: "Click the Run Detection button. The engine analyzes email patterns across multiple dimensions: volume, timing, sentiment, domains, and content. Results are ranked by severity (Critical, High, Medium, Low).",
                tip: "Detection runs on your full archive — larger archives produce more accurate baselines."),
            TutorialStep(title: "Review Results", icon: "list.bullet.rectangle", color: .red,
                what: "Examine detected anomalies by category.",
                how: "Results are grouped by type. Frequency Spikes show unusual volume from specific senders. Timing Anomalies show emails sent at unusual hours. Tone Shifts show sudden sentiment changes. New Domains flag first-time senders.",
                tip: "Critical and High severity anomalies should be investigated first — they represent the strongest deviations."),
            TutorialStep(title: "Investigate", icon: "magnifyingglass", color: .purple,
                what: "Drill into specific anomalies.",
                how: "Click any anomaly to see the affected emails. Review the email content, headers, and context to determine if the anomaly is benign or suspicious.",
                tip: "Cross-reference anomalies with the IT Admin header analysis to check for spoofing or authentication failures."),
            TutorialStep(title: "Export Findings", icon: "square.and.arrow.up", color: .green,
                what: "Save anomaly results for documentation.",
                how: "Export the anomaly report as CSV or include it in a forensic investigation report. Each finding includes the anomaly type, severity, affected emails, and detection criteria.",
                tip: "Include severity levels in your export — they help prioritize follow-up actions.")
        ],
        tips: [
            TutorialTip(icon: "chart.xyaxis.line", text: "The baseline is computed from your full archive — import all relevant data before running detection."),
            TutorialTip(icon: "clock", text: "Timing anomalies use the sender's typical hours — a 3am email from a 9-5 sender will flag."),
            TutorialTip(icon: "face.smiling", text: "Tone shifts compare recent sentiment against a contact's historical average."),
            TutorialTip(icon: "bell.badge", text: "Use Smart Alerts to set up automatic monitoring for specific anomaly types.")
        ]
    )

    // MARK: - IOC Extractor

    static let iocExtractor = FeatureTutorial(
        title: "How to Use IOC Extractor",
        icon: "bolt.shield.fill",
        overview: "The IOC (Indicators of Compromise) Extractor scans emails for security indicators: suspicious URLs, IP addresses, domains, file hashes, and email addresses associated with threats. Essential for incident response and threat hunting.",
        quickStart: "Click \"Extract IOCs\" to scan all emails. Results show URLs, IPs, domains, and email addresses found. Click any IOC to see which emails contain it and assess the risk.",
        steps: [
            TutorialStep(title: "Extract IOCs", icon: "magnifyingglass", color: .red,
                what: "Scan emails for security indicators.",
                how: "Click Extract to scan email bodies, headers, and attachments for URLs, IP addresses, domains, file hashes, and suspicious email addresses. Results are categorized by type.",
                tip: "The scanner checks both visible links and hidden URLs embedded in HTML."),
            TutorialStep(title: "Review Indicators", icon: "list.bullet", color: .orange,
                what: "Examine extracted IOCs by category.",
                how: "Browse results by tab: URLs, IPs, Domains, Hashes, Emails. Each indicator shows occurrence count and the emails containing it. High-frequency indicators may represent campaigns.",
                tip: "Raw IP addresses in email links are almost always suspicious — legitimate services use domain names."),
            TutorialStep(title: "Assess Risk", icon: "exclamationmark.triangle", color: .purple,
                what: "Evaluate the threat level of each IOC.",
                how: "Click an IOC to see context: which emails contain it, what the surrounding text says, and whether it appears in headers or body. Cross-reference with known threat intelligence.",
                tip: "Shortened URLs (bit.ly, tinyurl) are frequently used in phishing — treat them as higher risk."),
            TutorialStep(title: "Export for Response", icon: "square.and.arrow.up", color: .blue,
                what: "Export IOCs for your security team.",
                how: "Export the IOC list as CSV or STIX format for ingestion into your SIEM, firewall, or threat intelligence platform. Include email IDs for traceability.",
                tip: "Share the domain and IP lists with your network team for immediate blocking if confirmed malicious.")
        ],
        tips: [
            TutorialTip(icon: "globe", text: "Check extracted domains against your organization's allow-list before flagging."),
            TutorialTip(icon: "link", text: "URLs with '@' symbols or encoded characters are common phishing indicators."),
            TutorialTip(icon: "number", text: "Private IP ranges (10.x, 192.168.x) are filtered out automatically — only public IPs are shown.")
        ]
    )

    // MARK: - Keyword Monitor

    static let keywordMonitor = FeatureTutorial(
        title: "How to Use Keyword Monitor",
        icon: "text.badge.checkmark",
        overview: "Keyword Monitor lets you define watchlists of terms and phrases to scan across your email archive. Track specific keywords, names, project codes, or sensitive terms and see exactly where they appear with surrounding context.",
        quickStart: "Add keywords to your watchlist, then click \"Scan\" to search the entire archive. Results show each keyword's occurrence count with email context. Set up alerts for new matches on future imports.",
        steps: [
            TutorialStep(title: "Add Keywords", icon: "plus.circle", color: .blue,
                what: "Define terms to monitor.",
                how: "Type keywords, phrases, or patterns into the watchlist. You can add single words, multi-word phrases, or domain names. Group related terms with labels for organization.",
                tip: "Add both formal and informal versions of names — people use nicknames in emails."),
            TutorialStep(title: "Scan Archive", icon: "magnifyingglass", color: .green,
                what: "Search all emails for your keywords.",
                how: "Click Scan to search the full archive. Results show occurrence counts per keyword, with a list of matching emails for each. Context snippets show the surrounding text.",
                tip: "Case-insensitive by default — \"Project Alpha\" also finds \"project alpha\" and \"PROJECT ALPHA\"."),
            TutorialStep(title: "Review Matches", icon: "doc.text.magnifyingglass", color: .purple,
                what: "Examine keyword hits in context.",
                how: "Click a keyword to see all matching emails. Each result highlights the keyword in context so you can quickly assess relevance without reading the full email.",
                tip: "Look for keyword co-occurrences — two watchlist terms in the same email are often more significant.")
        ],
        tips: [
            TutorialTip(icon: "bell", text: "Combine with Smart Alerts to get notified when keywords appear in newly imported emails."),
            TutorialTip(icon: "textformat", text: "Use phrases for precision — monitoring \"insider trading\" is better than \"insider\" and \"trading\" separately."),
            TutorialTip(icon: "square.and.arrow.up", text: "Export keyword hit reports as CSV with email IDs, timestamps, and context snippets.")
        ]
    )

    // MARK: - Duplicate Manager

    static let duplicateManager = FeatureTutorial(
        title: "How to Use Duplicate Manager",
        icon: "doc.on.doc",
        overview: "The Duplicate Manager finds and removes exact and near-duplicate emails from your archive. It compares email content, headers, and metadata to identify copies, saving storage and reducing review volume for legal and forensic workflows.",
        quickStart: "Click \"Find Duplicates\" to scan. Results show groups of identical or similar emails. Review each group, select which copies to keep, and remove the rest. Near-duplicates show a similarity percentage.",
        steps: [
            TutorialStep(title: "Scan for Duplicates", icon: "magnifyingglass", color: .blue,
                what: "Find duplicate emails in your archive.",
                how: "Click Find Duplicates to compare all emails by content hash (exact) and fuzzy matching (near-duplicate). The scan groups identical emails together and ranks near-duplicates by similarity percentage.",
                tip: "Exact duplicates are safe to remove. Near-duplicates (>90% similarity) may differ in headers or minor edits."),
            TutorialStep(title: "Review Groups", icon: "rectangle.stack", color: .green,
                what: "Compare duplicate groups side by side.",
                how: "Each group shows the original and its duplicates. Click to compare content differences. The system highlights what's different between near-duplicates so you can decide which to keep.",
                tip: "Keep the earliest copy by date — it's the original. Later copies are forwards or re-sends."),
            TutorialStep(title: "Remove Duplicates", icon: "trash", color: .red,
                what: "Delete selected duplicate copies.",
                how: "Select duplicates to remove within each group, then confirm deletion. The original is preserved. Removal is logged in the forensic audit trail for chain of custody compliance.",
                tip: "For legal matters, document why you removed duplicates — deduplication is an accepted eDiscovery practice.")
        ],
        tips: [
            TutorialTip(icon: "percent", text: "Near-duplicate threshold is configurable — lower percentages catch more variations but may include false positives."),
            TutorialTip(icon: "doc.text", text: "Deduplication is standard in eDiscovery — it reduces review volume and costs."),
            TutorialTip(icon: "clock", text: "Run deduplication before review to avoid coding the same email multiple times.")
        ]
    )

    // MARK: - Email Timeline

    static let emailTimeline = FeatureTutorial(
        title: "How to Use Email Timeline",
        icon: "calendar.day.timeline.left",
        overview: "The Email Timeline provides an interactive chronological view of your email archive. Scroll through time to see when emails were sent, identify activity clusters, and spot gaps in communication. Essential for building event narratives.",
        quickStart: "Emails are displayed chronologically on a scrollable timeline. Click any point to see the email. Use the date range selector to focus on specific periods. Filter by sender or keyword to track specific threads of activity.",
        steps: [
            TutorialStep(title: "Browse Timeline", icon: "clock", color: .blue,
                what: "Scroll through emails chronologically.",
                how: "The timeline shows emails ordered by date. Each entry displays the sender, subject, and time. Scroll to navigate through time, or jump to specific dates using the date picker.",
                tip: "Zoom into dense periods to see individual emails — zoom out to spot activity patterns."),
            TutorialStep(title: "Filter Events", icon: "line.3.horizontal.decrease", color: .purple,
                what: "Focus on specific senders, topics, or periods.",
                how: "Use the filter bar to show only emails from specific senders, containing certain keywords, or within a date range. Multiple filters can be combined.",
                tip: "Filter by two parties to see their entire conversation timeline in isolation."),
            TutorialStep(title: "Identify Patterns", icon: "chart.xyaxis.line", color: .green,
                what: "Spot communication patterns and gaps.",
                how: "The density bar above the timeline shows email volume over time. Dense clusters indicate active periods. Gaps may indicate communication blackouts or data collection issues.",
                tip: "Gaps in an otherwise active communication pattern are significant — they may indicate deleted emails or a deliberate pause.")
        ],
        tips: [
            TutorialTip(icon: "bookmark", text: "Bookmark key timeline events to build a chronological narrative for reports."),
            TutorialTip(icon: "arrow.left.arrow.right", text: "Compare sent vs. received timelines to understand communication dynamics."),
            TutorialTip(icon: "printer", text: "Export the timeline as a visual report for presentations or court exhibits.")
        ]
    )

    // MARK: - Communication Patterns

    static let communicationPatterns = FeatureTutorial(
        title: "How to Use Communication Patterns",
        icon: "bubble.left.and.bubble.right.fill",
        overview: "Communication Patterns analyzes how people interact in your email archive. View contact frequency, hourly and daily activity patterns, response times, and communication network structures to understand relationship dynamics.",
        quickStart: "The Overview shows top contacts and activity heatmaps. Switch tabs to see Hourly Activity (when people email), Response Times (how fast people reply), and Network Analysis (who talks to whom).",
        steps: [
            TutorialStep(title: "Contact Stats", icon: "person.2", color: .blue,
                what: "See who communicates most.",
                how: "The top contacts list shows email volume per person, broken down by sent/received. Click a contact for their detailed communication profile including favorite topics and sentiment.",
                tip: "Contacts who both send and receive frequently are key relationship nodes."),
            TutorialStep(title: "Activity Patterns", icon: "clock", color: .green,
                what: "Discover when communication happens.",
                how: "The activity heatmap shows email density by hour and day of week. Dark cells = high activity. This reveals work patterns, time zones, and unusual activity windows.",
                tip: "Activity outside normal business hours may indicate urgency, different time zones, or automated messages."),
            TutorialStep(title: "Response Analysis", icon: "arrow.turn.up.right", color: .orange,
                what: "Measure how quickly people respond.",
                how: "Response time analysis shows average, median, and fastest/slowest reply times per contact. Thread analysis tracks how conversations develop over time.",
                tip: "Decreasing response times in a thread often indicate escalating urgency or importance."),
            TutorialStep(title: "Network View", icon: "point.3.connected.trianglepath.dotted", color: .purple,
                what: "Visualize communication relationships.",
                how: "The network diagram shows connections between contacts based on email exchanges. Thicker lines = more communication. Clusters reveal organizational groups or project teams.",
                tip: "Isolated nodes (people only connected to one other person) may be external contacts or one-time correspondents.")
        ],
        tips: [
            TutorialTip(icon: "globe", text: "Time zone differences explain activity in unexpected hours — check sender locations."),
            TutorialTip(icon: "chart.bar", text: "Export pattern data as CSV for custom analysis in spreadsheet or BI tools."),
            TutorialTip(icon: "person.3", text: "Large communication clusters often map to departments, projects, or deal teams.")
        ]
    )

    // MARK: - Relationship Graph

    static let relationshipGraph = FeatureTutorial(
        title: "How to Use Relationship Graph",
        icon: "point.3.connected.trianglepath.dotted",
        overview: "The Relationship Graph visualizes contact networks using a force-directed graph layout. See who connects to whom, identify central figures, discover hidden relationships, and understand organizational communication structures at a glance.",
        quickStart: "The graph loads automatically showing all contacts as nodes and email exchanges as edges. Drag nodes to rearrange. Click a node to see that contact's connections. Use the controls to adjust layout and filtering.",
        steps: [
            TutorialStep(title: "Explore the Graph", icon: "hand.point.up.left", color: .blue,
                what: "Navigate the contact network visually.",
                how: "Nodes represent contacts, edges represent email exchanges. Node size reflects email volume. Edge thickness shows communication frequency. Drag to pan, scroll to zoom, click nodes for details.",
                tip: "The largest nodes are your most active communicators — start analysis there."),
            TutorialStep(title: "Find Key Contacts", icon: "star.fill", color: .orange,
                what: "Identify the most connected and central people.",
                how: "Central nodes with many connections are information hubs. Look for contacts that bridge between clusters — they may be key decision-makers or information brokers.",
                tip: "A contact connecting two otherwise separate groups is strategically important — they control information flow."),
            TutorialStep(title: "Filter & Focus", icon: "line.3.horizontal.decrease", color: .purple,
                what: "Narrow the graph to specific relationships.",
                how: "Use filters to show only specific domains, time periods, or minimum connection strengths. This reduces visual clutter and reveals the most significant relationships.",
                tip: "Filter by domain to see intra-organizational vs. external communication patterns.")
        ],
        tips: [
            TutorialTip(icon: "arrow.triangle.2.circlepath", text: "The force-directed layout auto-arranges — clusters of tightly connected contacts group together naturally."),
            TutorialTip(icon: "camera", text: "Use the snapshot button to save the current graph view as an image for reports."),
            TutorialTip(icon: "link", text: "Dotted edges indicate indirect connections (shared contacts but no direct emails).")
        ]
    )

    // MARK: - Executive Dashboard

    static let executiveDashboard = FeatureTutorial(
        title: "How to Use Executive Dashboard",
        icon: "gauge.with.dots.needle.33percent",
        overview: "The Executive Dashboard provides a real-time, at-a-glance summary of your email archive with key performance indicators. See total volumes, category breakdowns, sentiment gauges, risk scores, and trend indicators — perfect for quick briefings and status checks.",
        quickStart: "The dashboard auto-populates with KPI cards showing your archive's key metrics. No action needed — just review the numbers. Click any card to drill down into the detailed analysis view for that metric.",
        steps: [
            TutorialStep(title: "Review KPIs", icon: "chart.bar", color: .blue,
                what: "Check key metrics at a glance.",
                how: "KPI cards show total emails, active contacts, date range, average sentiment, risk score, and category distribution. Color coding indicates status: green = good, yellow = attention, red = action needed.",
                tip: "The trend arrows show whether metrics are improving or declining compared to previous periods."),
            TutorialStep(title: "Drill Down", icon: "arrow.down.right.square", color: .purple,
                what: "Investigate any metric in detail.",
                how: "Click any KPI card to navigate to the full analysis view for that metric. For example, click the sentiment gauge to open full sentiment analysis, or the risk score to see anomaly details.",
                tip: "The dashboard is a navigation hub — use it to quickly jump to the area that needs attention."),
            TutorialStep(title: "Monitor Trends", icon: "chart.line.uptrend.xyaxis", color: .green,
                what: "Track how metrics change over time.",
                how: "Sparkline charts on each card show the trend direction. Hover for exact values at each time point. Consistent trends are expected; sudden changes warrant investigation.",
                tip: "A sudden drop in average sentiment across the archive may indicate a developing issue or conflict.")
        ],
        tips: [
            TutorialTip(icon: "arrow.clockwise", text: "The dashboard refreshes when you navigate to it — always shows current data."),
            TutorialTip(icon: "printer", text: "Print the dashboard for quick executive briefings or status meetings."),
            TutorialTip(icon: "person.crop.circle", text: "Different personas show different KPIs — switch personas to see security vs. legal vs. personal metrics.")
        ]
    )

    // MARK: - AI Assistant

    static let aiAssistant = FeatureTutorial(
        title: "How to Use AI Assistant",
        icon: "sparkles",
        overview: "The AI Assistant lets you ask natural language questions about your email archive. It uses on-device Apple Intelligence (FoundationModels) to analyze emails, summarize threads, find patterns, and answer complex queries — all without sending data off your device.",
        quickStart: "Type a question in the input bar at the bottom. The AI searches your archive, analyzes relevant emails, and generates a response. Try questions like \"What are the main topics?\" or \"Summarize emails from John about the project.\"",
        steps: [
            TutorialStep(title: "Ask Questions", icon: "text.bubble", color: .blue,
                what: "Query your archive in plain English.",
                how: "Type any question about your emails. The AI understands context: who sent what, when, about what topics, with what sentiment. It searches the archive and synthesizes an answer from multiple emails.",
                tip: "Be specific for better results: \"What did Sarah say about the budget in March?\" beats \"Tell me about the budget.\""),
            TutorialStep(title: "Follow Up", icon: "arrow.turn.down.right", color: .green,
                what: "Refine and explore with follow-up questions.",
                how: "After getting an answer, ask follow-ups to dig deeper. The AI maintains conversation context so you can progressively narrow your focus. Ask for summaries, comparisons, or specific details.",
                tip: "If the first answer is too broad, follow up with \"Focus on the emails between X and Y\" or \"Only from last month.\""),
            TutorialStep(title: "Review Sources", icon: "doc.text.magnifyingglass", color: .purple,
                what: "See which emails informed the AI's answer.",
                how: "The AI cites specific emails in its responses. Click cited emails to open them and verify the information. This ensures you can always trace answers back to source evidence.",
                tip: "Always verify key claims by checking the cited emails — AI can occasionally misinterpret context.")
        ],
        tips: [
            TutorialTip(icon: "cpu", text: "AI runs entirely on-device using Apple Intelligence — your emails never leave your Mac."),
            TutorialTip(icon: "desktopcomputer", text: "Requires macOS 26+ with Apple Intelligence enabled. Check System Settings > Apple Intelligence."),
            TutorialTip(icon: "questionmark.bubble", text: "Try these: \"Who sends the most emails?\", \"Summarize last week\", \"Find urgent items\", \"What topics does Sarah discuss?\""),
            TutorialTip(icon: "arrow.counterclockwise", text: "Clear the conversation to start fresh if responses become too focused on previous context.")
        ]
    )

    // MARK: - Knowledge Graph

    static let knowledgeGraph = FeatureTutorial(
        title: "How to Use Knowledge Graph",
        icon: "brain.head.profile",
        overview: "The Knowledge Graph maps entities (people, organizations, topics) and their relationships extracted from your email archive. Explore how contacts connect, which organizations discuss which topics, and discover hidden relationships across your data.",
        quickStart: "Build the graph first (it extracts entities from all emails), then explore using the visual browser. Click nodes to see connections, use the search to find specific entities, and filter by type (Person, Organization, Topic).",
        steps: [
            TutorialStep(title: "Build the Graph", icon: "hammer.fill", color: .blue,
                what: "Extract entities and relationships from emails.",
                how: "Click \"Build Knowledge Graph\" to scan all emails. The NLP engine extracts people, organizations, topics, and domains, then maps relationships based on co-occurrence in emails and threads.",
                tip: "Building takes a moment on large archives — the graph is cached so subsequent loads are instant."),
            TutorialStep(title: "Explore Entities", icon: "point.3.connected.trianglepath.dotted", color: .green,
                what: "Browse people, organizations, and topics.",
                how: "The graph shows entities as nodes colored by type. Click any node to see its connections, associated emails, and relationship strengths. Use the type filter to show only People, Organizations, or Topics.",
                tip: "High-degree nodes (many connections) are the most influential entities in your archive."),
            TutorialStep(title: "Find Connections", icon: "link", color: .purple,
                what: "Discover how entities relate to each other.",
                how: "Select two entities to find the shortest path between them. The graph shows intermediate connections and shared topics. This reveals indirect relationships you might not notice reading emails individually.",
                tip: "Two entities connected through a shared topic but no direct emails may indicate a hidden influence chain."),
            TutorialStep(title: "Search & Filter", icon: "magnifyingglass", color: .orange,
                what: "Find specific entities quickly.",
                how: "Use the search bar to find entities by name. Filter by type, minimum connection count, or relationship strength. The graph updates dynamically as you adjust filters.",
                tip: "Filter to show only high-strength connections for a cleaner, more meaningful visualization.")
        ],
        tips: [
            TutorialTip(icon: "arrow.clockwise", text: "Rebuild the graph after importing new emails to include new entities and relationships."),
            TutorialTip(icon: "chart.bar", text: "The Statistics panel shows total entities, connections, and top nodes by type."),
            TutorialTip(icon: "person.2", text: "Organizations are inferred from email domains — @company.com contacts are grouped under that organization.")
        ]
    )

    // MARK: - AI Digest

    static let aiDigest = FeatureTutorial(
        title: "How to Use AI Digest",
        icon: "doc.text.image",
        overview: "AI Digest generates concise, AI-powered summaries of your email archive for a chosen time period. Get a quick briefing on what happened today, this week, or this month — including key topics, important contacts, action items, and notable events.",
        quickStart: "Select a time period (Today, This Week, This Month), then click \"Generate Digest\". The AI analyzes emails from that period and produces a structured summary with highlights, key contacts, and action items.",
        steps: [
            TutorialStep(title: "Select Period", icon: "calendar", color: .blue,
                what: "Choose what timeframe to summarize.",
                how: "Pick from Today, This Week, This Month, or Custom Date Range. The digest will analyze only emails within that period, giving you a focused summary.",
                tip: "Weekly digests are the sweet spot — enough data for meaningful patterns, focused enough to be actionable."),
            TutorialStep(title: "Generate", icon: "sparkles", color: .purple,
                what: "Create the AI-powered summary.",
                how: "Click Generate to start. The AI processes relevant emails, extracts key themes, identifies important contacts, and surfaces action items. Generation takes a few seconds depending on volume.",
                tip: "The digest prioritizes unusual or noteworthy items over routine communications."),
            TutorialStep(title: "Review & Act", icon: "checkmark.circle", color: .green,
                what: "Read the summary and take action.",
                how: "The digest shows sections: Key Highlights, Top Contacts, Action Items, and Notable Events. Click any referenced email to open it. Use action items as your to-do list.",
                tip: "Share the digest with your team for a quick sync — it's a great meeting prep tool.")
        ],
        tips: [
            TutorialTip(icon: "cpu", text: "Digests are generated on-device — your email content stays private."),
            TutorialTip(icon: "desktopcomputer", text: "Requires macOS 26+ with Apple Intelligence. Falls back to NLP summaries on older systems."),
            TutorialTip(icon: "clock", text: "Generate a daily digest each morning to start your day with a clear picture of your inbox.")
        ]
    )

    // MARK: - Predictive Coding

    static let predictiveCoding = FeatureTutorial(
        title: "How to Use Predictive Coding",
        icon: "cpu",
        overview: "Predictive Coding (Technology-Assisted Review / TAR) uses machine learning to classify emails as relevant or non-relevant based on your coding decisions. Train the model with a seed set, then let it predict the rest — dramatically reducing manual review volume.",
        quickStart: "Start by coding a seed set of 30-50 emails manually (relevant/non-relevant). Then click \"Train Model\" to build the classifier. Review the model's predictions, correct any errors, and retrain to improve accuracy.",
        steps: [
            TutorialStep(title: "Code Seed Set", icon: "hand.point.up.left", color: .blue,
                what: "Manually code a representative sample.",
                how: "Review 30-50 emails and code each as Relevant or Non-Relevant. Choose a diverse sample including different topics, senders, and types. The model learns from these examples.",
                tip: "Include borderline cases in your seed set — they teach the model the most about your decision boundary."),
            TutorialStep(title: "Train Model", icon: "brain", color: .purple,
                what: "Build the prediction model from your coding.",
                how: "Click Train Model. The classifier analyzes your coded emails to learn patterns that distinguish relevant from non-relevant. Training accuracy and confusion matrix are displayed.",
                tip: "Aim for 80%+ accuracy on the validation set before applying predictions to the full archive."),
            TutorialStep(title: "Review Predictions", icon: "checkmark.circle", color: .green,
                what: "Check and correct the model's predictions.",
                how: "The model scores all uncoded emails with a relevance probability. Review predictions sorted by confidence — correct errors in the uncertain middle range. Each correction improves the model.",
                tip: "Focus corrections on emails near the 50% threshold — these border cases improve the model fastest."),
            TutorialStep(title: "Apply & Export", icon: "square.and.arrow.up", color: .orange,
                what: "Accept predictions and export results.",
                how: "Once accuracy is satisfactory, accept the model's predictions for remaining emails. Export the coded set with relevance scores for your review workflow or production.",
                tip: "Document your TAR methodology — courts require transparency about how predictive coding was applied.")
        ],
        tips: [
            TutorialTip(icon: "chart.bar", text: "The precision/recall curves help you choose the optimal relevance threshold."),
            TutorialTip(icon: "arrow.clockwise", text: "Retrain after correcting predictions — each round improves accuracy."),
            TutorialTip(icon: "doc.text", text: "TAR is widely accepted by courts when properly documented and validated."),
            TutorialTip(icon: "percent", text: "Sample-based QC (random check of predictions) validates the model's reliability for legal defensibility.")
        ]
    )

    // MARK: - GDPR Compliance

    static let gdprCompliance = FeatureTutorial(
        title: "How to Use GDPR Compliance",
        icon: "hand.raised.fill",
        overview: "The GDPR Compliance tool helps you identify and manage personal data in your email archive. Detect PII (personally identifiable information), generate Data Subject Access Request (DSAR) reports, and create redacted exports that protect privacy while preserving evidence.",
        quickStart: "Click \"Scan for PII\" to detect personal data across all emails. Review findings by type (names, emails, phone numbers, SSNs, etc.). Generate a DSAR report for a specific person, or create redacted exports.",
        steps: [
            TutorialStep(title: "Scan for PII", icon: "magnifyingglass", color: .blue,
                what: "Detect personal data in your archive.",
                how: "The PII scanner uses NLP pattern matching to find email addresses, phone numbers, SSNs, credit card numbers, passport numbers, and other personal identifiers. Results are categorized by type and risk level.",
                tip: "High-risk PII (SSNs, credit cards) is highlighted in red — prioritize these for protection or redaction."),
            TutorialStep(title: "Configure Report", icon: "doc.text", color: .green,
                what: "Set up the compliance report parameters.",
                how: "Choose the data subject (person whose data you're reporting on), select which PII types to include, set the date range, and choose the report format. Add your organization's details and DPO information.",
                tip: "GDPR requires responding to DSARs within 30 days — note the request date and set a reminder."),
            TutorialStep(title: "Generate Report", icon: "doc.richtext", color: .purple,
                what: "Create the compliance report.",
                how: "Click Generate to produce a GDPR-compliant report listing all personal data found for the specified data subject. The report includes data categories, sources, retention periods, and processing bases.",
                tip: "Review the report before sending — ensure no third-party personal data is inadvertently included."),
            TutorialStep(title: "Redact & Export", icon: "eye.slash", color: .orange,
                what: "Create privacy-safe exports.",
                how: "Use the redaction tool to automatically replace PII with [REDACTED] placeholders. Configure which PII types to redact. Export the redacted version for safe sharing.",
                tip: "Keep the unredacted original in secure storage — you may need it for legal proceedings.")
        ],
        tips: [
            TutorialTip(icon: "shield.checkered", text: "PII detection uses Luhn validation for credit cards and format checks for SSNs — reducing false positives."),
            TutorialTip(icon: "person.badge.minus", text: "The 'Right to Erasure' section helps document what data was deleted and when."),
            TutorialTip(icon: "globe", text: "GDPR applies to EU data subjects regardless of where your organization is located."),
            TutorialTip(icon: "lock.fill", text: "All PII scanning runs locally on your device — no personal data is sent to external services.")
        ]
    )

    // MARK: - Thread Summarizer

    static let threadSummarizer = FeatureTutorial(
        title: "How to Use Thread Summarizer",
        icon: "text.line.first.and.arrowtriangle.forward",
        overview: "Thread Summarizer groups related emails into conversation threads and generates summaries for each. See participants, key topics, decision points, action items, and sentiment trends for entire email conversations without reading every message.",
        quickStart: "Threads are auto-detected from subject lines and In-Reply-To headers. Click any thread to see its summary with participants, topic keywords, key decisions, and action items extracted from the conversation.",
        steps: [
            TutorialStep(title: "Browse Threads", icon: "list.bullet.indent", color: .blue,
                what: "See conversations grouped together.",
                how: "The thread list shows email conversations grouped by subject and reply chain. Each thread shows the participant count, message count, date range, and a preview of the latest message.",
                tip: "Long threads with many participants are often the most important conversations — start there."),
            TutorialStep(title: "Read Summaries", icon: "doc.text", color: .green,
                what: "Get the key points without reading every email.",
                how: "Click a thread to see its AI-generated summary including: participants, main topics, key decisions made, action items assigned, and a TL;DR. The sentiment arc shows how the conversation's tone evolved.",
                tip: "Action items are extracted automatically — use them as a task list to track follow-ups."),
            TutorialStep(title: "Track Sentiment", icon: "waveform.path.ecg", color: .purple,
                what: "See how conversation tone changes.",
                how: "The sentiment arc visualizes emotional tone from start to finish. Rising trends suggest resolution; declining trends may indicate conflict. Hover over points to see which message shifted the tone.",
                tip: "A sharp negative dip followed by silence often indicates an unresolved disagreement.")
        ],
        tips: [
            TutorialTip(icon: "link", text: "Threads are connected by In-Reply-To headers, References, and subject matching."),
            TutorialTip(icon: "person.2", text: "New participants joining a thread mid-conversation are highlighted — they may indicate escalation."),
            TutorialTip(icon: "doc.richtext", text: "Export thread summaries as part of investigation reports for a narrative overview.")
        ]
    )

    // MARK: - Batch Operations

    static let batchOperations = FeatureTutorial(
        title: "How to Use Batch Operations",
        icon: "square.stack.3d.up",
        overview: "Batch Operations lets you perform bulk actions on multiple emails at once. Tag, classify, export, or remove groups of emails efficiently. Essential for large-scale review workflows where processing one email at a time would take too long.",
        quickStart: "Select emails using the checkboxes or select-all, choose an operation from the action menu (Tag, Classify, Export, Remove), configure options, and apply. Progress is shown in real-time.",
        steps: [
            TutorialStep(title: "Select Emails", icon: "checkmark.circle", color: .blue,
                what: "Choose which emails to process.",
                how: "Use checkboxes to select individual emails, or Select All for the entire set. Filter first to narrow your selection — then Select All only selects filtered results.",
                tip: "Filter by category or date first, then Select All — this is the fastest way to target specific email groups."),
            TutorialStep(title: "Choose Operation", icon: "gearshape", color: .green,
                what: "Pick what action to perform.",
                how: "Available operations: Bulk Tag (apply evidence tags), Bulk Classify (run NLP classification), Bulk Export (CSV/DAT/PDF), and Bulk Remove. Each operation has its own configuration options.",
                tip: "Bulk Classify is great for initial triage — it categorizes hundreds of emails in seconds."),
            TutorialStep(title: "Configure & Apply", icon: "play.fill", color: .purple,
                what: "Set options and execute.",
                how: "Configure the operation parameters (tag type, export format, etc.) and click Apply. A progress bar shows completion. All operations are logged in the forensic audit trail.",
                tip: "Preview results on a small sample before applying to the full set — this catches configuration errors early.")
        ],
        tips: [
            TutorialTip(icon: "arrow.uturn.backward", text: "Bulk tag operations can be reversed — bulk remove cannot, so use it carefully."),
            TutorialTip(icon: "doc.text", text: "All batch operations are logged in the audit trail with counts and parameters."),
            TutorialTip(icon: "clock", text: "Large operations run in the background — you can continue working while they process.")
        ]
    )

    // MARK: - Smart Alerts

    static let smartAlerts = FeatureTutorial(
        title: "How to Use Smart Alerts",
        icon: "bell.badge.fill",
        overview: "Smart Alerts lets you create custom monitoring rules that trigger when specific conditions are met in your email archive. Set up alerts for keywords, senders, anomaly types, or communication patterns to stay informed about what matters most.",
        quickStart: "Create alert rules by specifying conditions (keyword match, sender pattern, anomaly type, etc.) and actions (highlight, tag, notify). Alerts trigger automatically when matching emails are found during import or analysis.",
        steps: [
            TutorialStep(title: "Create Rule", icon: "plus.circle", color: .blue,
                what: "Define what to watch for.",
                how: "Click 'New Alert' and specify conditions: keyword matches, sender/domain patterns, time-of-day windows, or anomaly types. Combine multiple conditions with AND/OR logic for precise targeting.",
                tip: "Start with broad rules and narrow them over time — too-specific rules miss important variations."),
            TutorialStep(title: "Set Actions", icon: "bell", color: .orange,
                what: "Choose what happens when triggered.",
                how: "Configure what happens on match: highlight in the email list, auto-tag with an evidence label, add to a review batch, or show a notification banner. Multiple actions can trigger simultaneously.",
                tip: "Use auto-tagging for compliance monitoring — it creates an audit trail of flagged items automatically."),
            TutorialStep(title: "Monitor", icon: "eye", color: .green,
                what: "Track alert activity over time.",
                how: "The alert dashboard shows which rules triggered, how often, and for which emails. Review triggered alerts to assess whether rules need tuning. Disable rules that generate too many false positives.",
                tip: "A rule that never triggers may be too narrow. A rule that always triggers is too broad. Aim for focused, actionable alerts.")
        ],
        tips: [
            TutorialTip(icon: "clock", text: "Alerts check both existing and newly imported emails — historical matches are shown too."),
            TutorialTip(icon: "slider.horizontal.3", text: "Adjust rule sensitivity over time based on false positive rates."),
            TutorialTip(icon: "square.and.arrow.up", text: "Export alert history for compliance documentation.")
        ]
    )

    // MARK: - Automation Rules

    static let automationRules = FeatureTutorial(
        title: "How to Use Automation Rules",
        icon: "gearshape.2.fill",
        overview: "Automation Rules let you create workflows that automatically process emails based on conditions you define. Auto-tag, classify, move, flag, or export emails when they match your criteria — saving hours of repetitive manual work.",
        quickStart: "Create rules with IF-THEN logic: IF an email matches conditions (sender, keywords, date, etc.) THEN perform actions (tag, classify, flag, export). Rules run automatically on import or can be triggered manually.",
        steps: [
            TutorialStep(title: "Define Conditions", icon: "tuningfork", color: .blue,
                what: "Set the criteria for matching emails.",
                how: "Choose from conditions: sender/recipient patterns, keyword matches, date ranges, attachment presence, NLP category, sentiment score, or domain. Combine conditions with AND/OR logic.",
                tip: "Use 'contains' for flexible matching and 'exact match' only when precision is critical."),
            TutorialStep(title: "Set Actions", icon: "play.fill", color: .green,
                what: "Choose what happens to matching emails.",
                how: "Available actions: auto-tag (evidence labels), auto-classify (NLP category), flag for review, add to batch, export, or apply custom labels. Actions execute in the order listed.",
                tip: "Chain multiple actions — e.g., tag as 'Relevant' AND add to 'Priority Review' batch."),
            TutorialStep(title: "Test & Activate", icon: "checkmark.circle", color: .purple,
                what: "Verify the rule works correctly.",
                how: "Use 'Test Rule' to see how many current emails would match without actually applying changes. Review the preview, adjust if needed, then activate the rule for automatic processing.",
                tip: "Always test on existing data before activating — a misconfigured rule can bulk-tag hundreds of emails incorrectly.")
        ],
        tips: [
            TutorialTip(icon: "arrow.triangle.2.circlepath", text: "Rules run on import automatically — new emails are processed as they're added."),
            TutorialTip(icon: "pause.circle", text: "Disable rules temporarily without deleting them — useful for fine-tuning."),
            TutorialTip(icon: "doc.text", text: "All automated actions are logged in the audit trail with the rule name as the source.")
        ]
    )

    // MARK: - Attachment Gallery

    static let attachmentGallery = FeatureTutorial(
        title: "How to Use Attachments",
        icon: "paperclip",
        overview: "The Attachment Gallery shows all file attachments from your email archive in a visual grid. Browse, preview, filter by file type, and search attachment content. Extracted text from PDFs and images (via OCR) is searchable.",
        quickStart: "Browse attachments as a visual grid showing thumbnails and file details. Filter by type (images, PDFs, documents, spreadsheets). Click any attachment to preview its content and see which email it came from.",
        steps: [
            TutorialStep(title: "Browse", icon: "square.grid.2x2", color: .blue,
                what: "View all attachments visually.",
                how: "The grid shows attachment thumbnails with filename, size, and type. Scroll through all attachments or switch to list view for detailed information. Sort by name, size, date, or type.",
                tip: "Large attachments are often the most important — sort by size to find significant documents quickly."),
            TutorialStep(title: "Filter & Search", icon: "magnifyingglass", color: .green,
                what: "Find specific attachments.",
                how: "Filter by file type (Images, PDFs, Documents, Spreadsheets, Archives, Other). Search by filename or extracted content — the search index includes OCR text from images and extracted text from PDFs.",
                tip: "Search extracted content to find information inside PDFs and scanned documents."),
            TutorialStep(title: "Preview & Export", icon: "eye", color: .purple,
                what: "View attachment content and save files.",
                how: "Click an attachment to preview it inline (images, PDFs, text). See which email it came from and navigate to that email. Export individual files or batch-export selected attachments.",
                tip: "Preview checks attachment content without opening external apps — safer for potentially suspicious files.")
        ],
        tips: [
            TutorialTip(icon: "doc.text.magnifyingglass", text: "PDF text extraction works on most PDFs. Scanned documents use OCR via Apple Vision framework."),
            TutorialTip(icon: "exclamationmark.triangle", text: "Be cautious opening executable attachments (.exe, .bat, .scr) — preview text content only."),
            TutorialTip(icon: "arrow.down.circle", text: "Batch export saves all selected attachments to a folder — useful for evidence collection.")
        ]
    )

    // MARK: - Archive Comparison

    static let archiveComparison = FeatureTutorial(
        title: "How to Use Archive Comparison",
        icon: "arrow.left.arrow.right.square",
        overview: "Archive Comparison lets you compare two email archives side by side. Find emails that exist in one archive but not the other, detect modifications, and identify what's new, changed, or missing — essential for data integrity verification.",
        quickStart: "Load two archives, then click \"Compare\". Results show emails unique to each archive and emails present in both. Modified emails (same thread but different content) are highlighted for review.",
        steps: [
            TutorialStep(title: "Load Archives", icon: "tray.2", color: .blue,
                what: "Select two archives to compare.",
                how: "The current archive is automatically loaded as Archive A. Import or select a second archive as Archive B. Both archives can be MBOX, EML, or any supported format.",
                tip: "Compare an original archive against a later export to verify nothing was added, removed, or modified."),
            TutorialStep(title: "Run Comparison", icon: "arrow.left.arrow.right", color: .green,
                what: "Analyze differences between archives.",
                how: "Click Compare to match emails by Message-ID, subject, sender, and date. Results categorize emails as: Only in A, Only in B, In Both (identical), or In Both (modified).",
                tip: "Modified emails are the most interesting — they may indicate tampering or forwarded/edited copies."),
            TutorialStep(title: "Review Differences", icon: "doc.text.magnifyingglass", color: .purple,
                what: "Examine what changed.",
                how: "Click any difference to see a side-by-side comparison. Modified emails show exactly what changed between the two versions. Missing emails are listed with full metadata for investigation.",
                tip: "Document comparison results — they're essential for chain of custody and data integrity arguments.")
        ],
        tips: [
            TutorialTip(icon: "lock.shield", text: "Use comparison after preservation to verify no emails were modified during the legal hold."),
            TutorialTip(icon: "doc.text", text: "Export the comparison report as evidence of data integrity verification."),
            TutorialTip(icon: "number", text: "Matching uses Message-ID first (most reliable), then falls back to subject+sender+date.")
        ]
    )

    // MARK: - Background Findings

    static let backgroundFindings = FeatureTutorial(
        title: "How to Use Background Findings",
        icon: "bell.and.waves.left.and.right",
        overview: "Background Findings shows results from automated background analysis that runs proactively on your email archive. The system continuously monitors for anomalies, security threats, PII exposure, and notable patterns without you having to manually trigger scans.",
        quickStart: "Findings appear automatically as the background engine detects noteworthy items. Review findings by category (Security, Anomaly, PII, Pattern). Click any finding to see affected emails and recommended actions.",
        steps: [
            TutorialStep(title: "Review Findings", icon: "list.bullet", color: .blue,
                what: "Check what the system detected.",
                how: "Findings are listed with severity (Critical, High, Medium, Low), category, and description. The most recent findings appear at the top. Each finding links to the specific emails that triggered it.",
                tip: "Critical and High findings deserve immediate attention — they represent significant anomalies or threats."),
            TutorialStep(title: "Take Action", icon: "hand.tap", color: .green,
                what: "Respond to findings.",
                how: "Click a finding to see details and recommended actions. You can tag affected emails, add them to a review batch, or navigate to the specialized tool (Anomaly Detection, IOC Extractor, etc.) for deeper investigation.",
                tip: "Mark findings as 'Acknowledged' after reviewing to keep the list focused on new discoveries."),
            TutorialStep(title: "Configure Monitoring", icon: "slider.horizontal.3", color: .purple,
                what: "Adjust what gets monitored.",
                how: "Configure which categories to monitor and sensitivity levels. Increase sensitivity for security-critical archives or decrease for personal email to reduce noise.",
                tip: "Balance sensitivity with noise — too many low-priority findings can cause alert fatigue.")
        ],
        tips: [
            TutorialTip(icon: "clock", text: "Background analysis runs during idle time — it won't slow down your active work."),
            TutorialTip(icon: "bell", text: "New findings trigger a subtle notification in the sidebar — look for the badge count."),
            TutorialTip(icon: "cpu", text: "All analysis runs locally on your device — no data is sent externally.")
        ]
    )

    // MARK: - Custodian Panel

    static let custodianPanel = FeatureTutorial(
        title: "How to Use Custodian Management",
        icon: "person.badge.key.fill",
        overview: "The Custodian Panel manages data custodians — the people whose emails are being collected and reviewed. Track custodian information, assign emails to custodians, manage legal holds, and document the chain of custody for each custodian's data.",
        quickStart: "Add custodians with their names, roles, and email addresses. The system auto-matches emails to custodians by sender/recipient address. Place legal holds on specific custodians to preserve their data.",
        steps: [
            TutorialStep(title: "Add Custodians", icon: "person.badge.plus", color: .blue,
                what: "Register people whose data you're managing.",
                how: "Click 'Add Custodian' and enter their name, role, department, and known email addresses. The system uses these addresses to automatically associate emails with the custodian.",
                tip: "Add all known email aliases for each custodian — people often have multiple addresses."),
            TutorialStep(title: "Place Legal Holds", icon: "lock.shield", color: .red,
                what: "Preserve a custodian's data.",
                how: "Select a custodian and click 'Place Legal Hold'. This logs the hold in the audit trail with timestamp and reason. The hold status is tracked and can be lifted when the matter concludes.",
                tip: "Document the legal basis for each hold — this information may be required in court proceedings."),
            TutorialStep(title: "Track Chain of Custody", icon: "link", color: .green,
                what: "Document who handled the data and when.",
                how: "Every action on a custodian's emails is logged: collection, review, export, and production. The chain of custody report shows a complete timeline of data handling for each custodian.",
                tip: "Export the chain of custody before production — it demonstrates proper evidence handling procedures.")
        ],
        tips: [
            TutorialTip(icon: "envelope", text: "Emails are auto-matched to custodians by From/To addresses — verify matches for accuracy."),
            TutorialTip(icon: "doc.text", text: "Legal hold notices should be issued separately — this tool tracks the hold status, not the notice itself."),
            TutorialTip(icon: "clock", text: "Review and release holds periodically — maintaining holds beyond their legal necessity creates risk.")
        ]
    )

    // MARK: - Near Duplicates

    static let nearDuplicates = FeatureTutorial(
        title: "How to Use Near Duplicate Detection",
        icon: "doc.on.doc.fill",
        overview: "Near Duplicate Detection uses fuzzy matching to find emails that are similar but not identical. Unlike exact deduplication, this catches forwarded emails, slight edits, and reformatted copies — reducing review volume while preserving unique content.",
        quickStart: "Set the similarity threshold (default 85%), then click \"Detect\". Results show groups of similar emails with similarity percentages. Review each group to decide which variants to keep for your review set.",
        steps: [
            TutorialStep(title: "Set Threshold", icon: "slider.horizontal.3", color: .blue,
                what: "Choose how similar emails need to be.",
                how: "The similarity threshold (0-100%) determines how closely emails must match to be grouped. Higher thresholds (90%+) catch near-identical copies. Lower thresholds (70-80%) catch more variations including reformatted or forwarded versions.",
                tip: "Start at 85% — it catches most meaningful duplicates without too many false positives."),
            TutorialStep(title: "Review Groups", icon: "rectangle.stack", color: .green,
                what: "Compare similar emails side by side.",
                how: "Each group shows the 'anchor' email and its near-duplicates with similarity scores. Click to see a diff view highlighting exactly what changed between versions — added text, removed text, or reformatting.",
                tip: "Forwarded emails often add \"FW:\" prefix and a forwarding header — these are common near-duplicates."),
            TutorialStep(title: "Consolidate", icon: "arrow.triangle.merge", color: .purple,
                what: "Select representative emails from each group.",
                how: "For each group, select the most complete version to keep in your review set. Mark others as duplicates. This reduces review volume while ensuring no unique content is lost.",
                tip: "In legal review, keep all versions if any contain unique annotations, replies, or legal significance.")
        ],
        tips: [
            TutorialTip(icon: "percent", text: "Similarity is based on content comparison, not just subject/sender — it catches subtle edits."),
            TutorialTip(icon: "doc.text", text: "Near-deduplication is accepted in eDiscovery — document your threshold for defensibility."),
            TutorialTip(icon: "chart.bar", text: "The summary shows total emails, groups found, and potential reduction percentage.")
        ]
    )
    // MARK: - Topic Clusters

    static let topicClusters = FeatureTutorial(
        title: "How to Use Topic Clusters",
        icon: "circle.grid.3x3.fill",
        overview: "Topic Clusters uses NLP to automatically group your emails by content similarity. It discovers the main themes in your archive, ranks them by volume, and lets you filter emails by topic — revealing what your archive is really about.",
        quickStart: "The view auto-computes clusters when loaded. Browse topics sorted by email count. Click a cluster to see all emails in that topic. Use the quality score to gauge clustering accuracy.",
        steps: [
            TutorialStep(title: "View Clusters", icon: "circle.grid.3x3", color: .blue,
                what: "See auto-discovered topics in your archive.",
                how: "Topics are computed using TF-IDF keyword extraction and grouped by similarity. Each cluster shows its top keywords, email count, and representative subject lines.",
                tip: "The silhouette score (0-1) indicates clustering quality — above 0.5 is good, above 0.7 is excellent."),
            TutorialStep(title: "Explore Topics", icon: "magnifyingglass", color: .green,
                what: "Drill into specific topic clusters.",
                how: "Click any cluster to see all emails belonging to that topic. The top keywords highlight what defines the cluster. Sort clusters by email count, keyword strength, or date.",
                tip: "Small clusters with unique keywords often contain the most interesting or specialized content."),
            TutorialStep(title: "Filter by Topic", icon: "line.3.horizontal.decrease", color: .purple,
                what: "Use topics to filter your email list.",
                how: "Click 'Apply Filter' on a cluster to filter the main email list to only show emails from that topic. Clear the filter to return to the full list.",
                tip: "Combine topic filters with other search criteria for precise email discovery.")
        ],
        tips: [
            TutorialTip(icon: "arrow.clockwise", text: "Re-compute clusters after importing new emails to include them in the analysis."),
            TutorialTip(icon: "textformat", text: "Keywords are extracted using NLP noun/adjective analysis with stopword filtering."),
            TutorialTip(icon: "chart.bar", text: "The distribution chart shows how emails spread across topics — uneven distribution is normal.")
        ]
    )

    // MARK: - Chain of Custody

    static let chainOfCustody = FeatureTutorial(
        title: "How to Use Chain of Custody",
        icon: "link",
        overview: "Chain of Custody tracks every action performed on your email evidence — imports, access, exports, and modifications. It creates a tamper-evident timeline with cryptographic verification, essential for legal proceedings where evidence handling must be documented.",
        quickStart: "The timeline shows all events automatically. Click \"Record Event\" to manually log an action. Use \"Verify Integrity\" to check the audit chain hasn't been tampered with. Export reports for court filings.",
        steps: [
            TutorialStep(title: "Review Timeline", icon: "clock", color: .blue,
                what: "See every action taken on the evidence.",
                how: "The event timeline shows chronological entries for imports, access events, exports, and manual recordings. Each entry shows the action type, actor, timestamp, and affected email count.",
                tip: "Events are logged automatically — you don't need to manually record routine actions like viewing emails."),
            TutorialStep(title: "Verify Integrity", icon: "checkmark.shield", color: .green,
                what: "Confirm the audit trail hasn't been tampered with.",
                how: "Click \"Verify Integrity\" to run cryptographic verification on the entire chain. Each event is HMAC-linked to the previous one — any modification breaks the chain and is detected immediately.",
                tip: "Run verification before exporting reports to confirm chain integrity for court submission."),
            TutorialStep(title: "Record Events", icon: "square.and.pencil", color: .orange,
                what: "Manually log custody transfer or handling events.",
                how: "Click \"Record Event\" to add entries like evidence transfers, storage location changes, or reviewer assignments. Enter the event type, description, and actor name.",
                tip: "Record physical custody transfers (USB drives, hard copies) that the system can't detect automatically."),
            TutorialStep(title: "Export Reports", icon: "doc.text", color: .purple,
                what: "Generate custody documentation for legal proceedings.",
                how: "\"Export Audit Trail\" produces a text log of all events. \"Export PDF Report\" generates a formatted, print-ready custody report with verification status and complete timeline.",
                tip: "Include the integrity verification result in your report — it proves the chain hasn't been altered.")
        ],
        tips: [
            TutorialTip(icon: "lock.fill", text: "HMAC-SHA256 chaining means even a single character change in any event invalidates the entire chain."),
            TutorialTip(icon: "person.fill", text: "Set your examiner name in settings — it's recorded as the actor for all your events."),
            TutorialTip(icon: "clock", text: "Timestamps use ISO-8601 format and are recorded at the moment of action — they cannot be backdated.")
        ]
    )

    // MARK: - Bates Numbering

    static let batesNumbering = FeatureTutorial(
        title: "How to Use Bates Numbering",
        icon: "number.square.fill",
        overview: "Bates Numbering assigns unique, sequential identifiers to every email in your archive for legal document management. These tamper-proof identifiers (e.g., CASE001-000001) enable precise document referencing in court filings, depositions, and production sets.",
        quickStart: "Set your prefix (e.g., \"CASE001\"), choose padding length, then click \"Assign Bates Numbers\". Every email gets a unique sequential number. Export a Bates index for your records.",
        steps: [
            TutorialStep(title: "Configure Prefix", icon: "textformat", color: .blue,
                what: "Set the identifier format for your case.",
                how: "Enter a prefix (typically a case number or short code) and choose the zero-padding length (e.g., 6 digits = 000001). The preview shows how numbers will look: PREFIX-000001, PREFIX-000002, etc.",
                tip: "Use a prefix that uniquely identifies the case and production set — e.g., \"SMITH_v_JONES_001\"."),
            TutorialStep(title: "Assign Numbers", icon: "number", color: .green,
                what: "Apply sequential Bates numbers to all emails.",
                how: "Click \"Assign Bates Numbers\" to number every email in your archive sequentially. Numbers are assigned in chronological order (earliest email = lowest number). Assignment is logged in the audit trail.",
                tip: "Assign numbers after deduplication and before production — renumbering after production causes confusion."),
            TutorialStep(title: "Export Index", icon: "square.and.arrow.up", color: .purple,
                what: "Generate a Bates number reference index.",
                how: "Export produces a CSV mapping each Bates number to its email subject, sender, date, and file hash. This index is your master reference for the numbered document set.",
                tip: "Keep the Bates index with your case file — it's the key to finding specific documents by number.")
        ],
        tips: [
            TutorialTip(icon: "arrow.counterclockwise", text: "Bates numbers can be reassigned — but only do this before sharing the numbered set externally."),
            TutorialTip(icon: "doc.text", text: "Bates numbers appear in all exports: DAT load files, CSV reports, privilege logs, and PDF reports."),
            TutorialTip(icon: "lock.fill", text: "Once assigned, Bates numbers are stored with SHA-256 hashes to prevent tampering.")
        ]
    )

    // MARK: - Review Batches

    static let reviewBatches = FeatureTutorial(
        title: "How to Use Review Batches",
        icon: "rectangle.stack.badge.play",
        overview: "Review Batches organizes emails into manageable groups for systematic document review. Create batches by size, assign them to reviewers, and track review progress across the entire document set — essential for large-scale litigation review workflows.",
        quickStart: "Set your preferred batch size (default 50 emails), then click \"Create Batches\". The system divides your emails into sequential batches. Work through each batch, tagging and coding emails as you go.",
        steps: [
            TutorialStep(title: "Create Batches", icon: "rectangle.stack", color: .blue,
                what: "Divide emails into review groups.",
                how: "Set the batch size (number of emails per batch) and click Create. Emails are divided sequentially. The overview shows total batches, emails per batch, and estimated review time based on your average coding speed.",
                tip: "50 emails per batch is a good default — small enough to complete in one session, large enough to be efficient."),
            TutorialStep(title: "Review Emails", icon: "doc.text.magnifyingglass", color: .green,
                what: "Work through each batch systematically.",
                how: "Select a batch to start reviewing. Each email is presented for coding — tag it as Relevant, Privileged, Irrelevant, or Flagged. Your progress within each batch is tracked with a completion percentage.",
                tip: "Work through batches in order — this ensures consistent coverage and makes progress tracking meaningful."),
            TutorialStep(title: "Track Progress", icon: "chart.bar.fill", color: .purple,
                what: "Monitor review completion across all batches.",
                how: "The progress dashboard shows which batches are complete, in progress, or not started. See total emails reviewed, coding distribution, average speed, and estimated time remaining.",
                tip: "Use the QC (quality control) sample to spot-check completed batches for coding consistency.")
        ],
        tips: [
            TutorialTip(icon: "person.2", text: "In team review, assign different batches to different reviewers to avoid overlap."),
            TutorialTip(icon: "arrow.clockwise", text: "You can re-open completed batches to revise coding decisions."),
            TutorialTip(icon: "chart.pie", text: "The coding distribution chart helps identify if your relevance criteria are too broad or too narrow.")
        ]
    )

    static let emailTags = FeatureTutorial(
        title: "Email Labels & AI Tags",
        icon: "tag.fill",
        overview: "Every email in the list can carry small colored labels (pills) that tell you what it is at a glance. Some labels are plain facts, some are the AI's best guess, and some are labels you add yourself. You are always in charge — anything the AI gets wrong takes one click to fix.",
        quickStart: "Click the brain button (AI) above the list to turn smart labels on. Blue AI pills show what the computer thinks each email is. If a label is wrong, click the pill and then click the wrong label to remove it. Use the small tag button on any row to add your own labels.",
        steps: [
            TutorialStep(title: "Read the Pills", icon: "tag", color: .blue,
                what: "Three kinds of labels, three colors.",
                how: "GRAY (BS = Basic) shows plain facts read straight from the email: Sent, Received, Has Attachment. BLUE (AI) shows what the on-device AI concluded: a category like Newsletter or Personal, a mood, a priority, or a phishing warning. PURPLE (MN = Manual) shows labels you added yourself.",
                tip: "Your purple manual labels always win — they are never overwritten by the AI."),
            TutorialStep(title: "Turn AI Labels On", icon: "brain", color: .purple,
                what: "The brain button switches between facts-only and smart labels.",
                how: "Click the brain (AI) button above the list. Off = every row shows only plain facts. On = rows show the AI's analysis, and the AI filter chips (High Priority, Phishing…) light up so you can filter by them.",
                tip: "The analysis runs once on your Mac and is saved — turning AI on later is instant, and nothing is sent to the internet."),
            TutorialStep(title: "Fix a Wrong AI Label", icon: "hand.tap", color: .orange,
                what: "One click removes a wrong label.",
                how: "Click the blue AI pill on the email, then click the label that is wrong — it disappears from that email everywhere (pills, counts, filters). Changed your mind? The same menu has 'Restore removed AI tags'.",
                tip: "Corrections are remembered — they survive closing and reopening the app."),
            TutorialStep(title: "Add Your Own Label", icon: "plus.circle", color: .green,
                what: "Tag emails the way YOU think about them.",
                how: "Click the small tag button at the end of any row. Pick a category (Personal, Newsletter…), a mood, a priority, or Phishing. A checkmark shows what is applied; click again to remove. Your labels appear as a purple MN pill.",
                tip: "Manual labels are great for marking emails the AI cannot know about — 'this one matters to my case'."),
            TutorialStep(title: "Filter by Labels", icon: "line.3.horizontal.decrease.circle", color: .cyan,
                what: "Labels become one-click filters.",
                how: "The chip row above the list and the Smart Tags section in the sidebar filter the WHOLE archive by these labels — click 'High Priority' to see only high-priority emails, however many thousands there are.",
                tip: "Combine chips with search: 'invoice' + the Phishing chip finds suspicious invoice emails.")
        ],
        tips: [
            TutorialTip(icon: "checkmark.shield", text: "All analysis happens on this Mac. Your emails never leave your computer."),
            TutorialTip(icon: "exclamationmark.triangle", text: "AI labels are good guesses, not facts — the pill menu says so, and correcting a wrong one takes one click."),
            TutorialTip(icon: "arrow.uturn.backward", text: "Removed a label by mistake? Open the pill menu and click Restore."),
            TutorialTip(icon: "gearshape", text: "Simple tells you what to do (category, importance, phishing). Turn on Pro for analyst labels — sentiment, medium priority, evidence.")
        ]
    )

    static let piiReport = FeatureTutorial(
        title: "PII Report",
        icon: "person.text.rectangle",
        overview: "Finds personally identifiable information hiding in your emails — phone numbers, credit cards, SSNs, IP addresses, passports and more. Everything is detected on this Mac; nothing is uploaded. Useful before sharing or producing emails, and for GDPR/privacy reviews.",
        quickStart: "Click the PII button under the email list (or Scan for PII in the e-discovery workflow). Findings arrive grouped by type with the source email named for each. Use the chips to jump to one type, AI Clean-up to remove wrong matches, and Export CSV for the full list.",
        steps: [
            TutorialStep(title: "Scan the Current Filter", icon: "magnifyingglass", color: .blue,
                what: "The report covers exactly what the list shows.",
                how: "Whatever filter is active (a sender, a date range, a search) defines the scan. Up to 2,000 emails are scanned per run — the report says so plainly if your filter is larger.",
                tip: "Narrow the filter first to scan a specific person or period."),
            TutorialStep(title: "Read the Findings", icon: "list.bullet", color: .purple,
                what: "Grouped by type, riskiest first.",
                how: "Each type (SSN, credit card, phone…) shows its count and risk score; every value names the email it was found in. Click a chip to see only that type.",
                tip: "Risk 7+ types (SSN, cards, passports) deserve review before any export leaves your hands."),
            TutorialStep(title: "Clean Up Wrong Matches", icon: "sparkles", color: .orange,
                what: "Pattern matching makes mistakes — one click fixes them.",
                how: "AI Clean-up (Apple Intelligence, on-device) re-checks entries and removes ones that aren't really PII, like timestamps or order numbers. Undo restores them all.",
                tip: "Repeated clicks are safe — checked entries are never re-judged."),
            TutorialStep(title: "Export the Evidence", icon: "square.and.arrow.up", color: .green,
                what: "A spreadsheet of every finding.",
                how: "Export CSV writes type, value, risk, context and source email for the complete list — including entries past the 200-per-type display cap.",
                tip: "Attach the CSV to a privacy review or redaction pass.")
        ],
        tips: [
            TutorialTip(icon: "checkmark.shield", text: "Detection is 100% on-device. The report exists only while open — nothing is stored unless you export."),
            TutorialTip(icon: "exclamationmark.triangle", text: "Automated pattern detection — some entries may not be correct; the header says so and the tools above fix it.")
        ]
    )
}
// swiftlint:enable type_body_length file_length
