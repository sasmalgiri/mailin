import SwiftUI

struct WelcomeHubView: View {
    @ObservedObject private var personaManager = PersonaManager.shared
    @EnvironmentObject private var storeManager: StoreManager
    var onOpenArchive: () -> Void
    var onBrowseFiles: () -> Void

    @State private var showPersonaSwitcher = false
    @State private var animateCards = false

    private var persona: PersonaManager.Persona { personaManager.selectedPersona }

    var body: some View {
        #if os(iOS)
        iOSLayout
        #else
        macOSLayout
        #endif
    }

    // MARK: - macOS Layout

    #if os(macOS)
    private var macOSLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                    .padding(.bottom, Spacing.large)

                quickActionsBar
                    .padding(.horizontal, Spacing.xLarge)
                    .padding(.bottom, Spacing.large)

                featureShowcase
                    .padding(.horizontal, Spacing.xLarge)
                    .padding(.bottom, Spacing.large)

                supportedFormatsSection
                    .padding(.bottom, Spacing.medium)

                privacyFooter
                    .padding(.bottom, Spacing.xLarge)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.backgroundPrimary)
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.15)) { animateCards = true } }
    }
    #endif

    // MARK: - iOS Layout

    #if os(iOS)
    private var iOSLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                    .padding(.bottom, Spacing.medium)

                quickActionsBar
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.large)

                featureShowcase
                    .padding(.horizontal, Spacing.medium)
                    .padding(.bottom, Spacing.large)

                supportedFormatsSection
                    .padding(.bottom, Spacing.medium)

                privacyFooter
                    .padding(.bottom, Spacing.large)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.15)) { animateCards = true } }
    }
    #endif

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: Spacing.small) {
            Spacer().frame(height: Spacing.large)

            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(persona.accentColor.gradient)
                .shadow(color: persona.accentColor.opacity(0.3), radius: 12, y: 4)

            Text("mailin")
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)

            Text(personaManager.config.welcomeTitle)
                .font(Typography.title3)
                .foregroundStyle(persona.accentColor)

            Button {
                showPersonaSwitcher = true
            } label: {
                HStack(spacing: Spacing.xxSmall) {
                    Image(systemName: persona.icon)
                    Text(persona.displayName)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(Typography.caption1)
                .foregroundStyle(persona.accentColor)
                .padding(.horizontal, Spacing.small)
                .padding(.vertical, Spacing.xxSmall)
                .background(persona.accentColor.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPersonaSwitcher) {
                personaSwitcherSheet
            }

            // Discoverable upgrade entry — the paywall was previously only
            // reachable via Settings, which App Review (and users) missed.
            if storeManager.currentTier < .professional {
                Button {
                    storeManager.showPaywall = true
                } label: {
                    HStack(spacing: Spacing.xxSmall) {
                        Image(systemName: "sparkles")
                        Text(storeManager.currentTier == .free ? "Unlock Pro" : "Upgrade to Professional")
                    }
                    .font(Typography.caption1.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.xxSmall)
                    .background(
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(Capsule())
                    .shadow(color: .purple.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unlock Pro — view subscription options")
            }

            Text(personaManager.config.emptyStateMessage)
                .font(Typography.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, Spacing.xxSmall)
        }
        .padding(.horizontal, Spacing.medium)
    }

    // MARK: - Quick Actions

    private var quickActionsBar: some View {
        HStack(spacing: Spacing.small) {
            Button(action: onOpenArchive) {
                Label("Open Email Archive", systemImage: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: onBrowseFiles) {
                Label("Browse Files", systemImage: "doc.badge.plus")
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Feature Showcase

    private var featureShowcase: some View {
        VStack(spacing: Spacing.medium) {
            ForEach(Array(orderedCategories.enumerated()), id: \.element.title) { index, category in
                featureCategorySection(category, index: index)
            }
        }
    }

    private func featureCategorySection(_ category: FeatureCategory, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: category.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(category.color)
                Text(category.title)
                    .font(Typography.headline)
                if category.isPrimary {
                    Text("FOR YOU")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundColor(persona.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(persona.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            LazyVGrid(columns: featureColumns, spacing: Spacing.xSmall) {
                ForEach(category.features) { feature in
                    featureCard(feature)
                }
            }
        }
        .opacity(animateCards ? 1 : 0)
        .offset(y: animateCards ? 0 : 12)
        .animation(.easeOut(duration: 0.4).delay(Double(index) * 0.08), value: animateCards)
    }

    private var featureColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.flexible(), spacing: Spacing.xSmall), GridItem(.flexible(), spacing: Spacing.xSmall)]
        #else
        [GridItem(.flexible(), spacing: Spacing.xSmall),
         GridItem(.flexible(), spacing: Spacing.xSmall),
         GridItem(.flexible(), spacing: Spacing.xSmall)]
        #endif
    }

    private func featureCard(_ feature: FeatureItem) -> some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: feature.icon)
                .font(.body)
                .foregroundStyle(feature.color.gradient)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(feature.name)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(feature.tagline)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .background(Color(.secondarySystemGroupedBackground))
        #else
        .background(AppColors.backgroundSecondary.opacity(0.7))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
    }

    // MARK: - Supported Formats

    private var supportedFormatsSection: some View {
        VStack(spacing: Spacing.xSmall) {
            Text("SUPPORTED FORMATS")
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            HStack(spacing: Spacing.xSmall) {
                ForEach(["MBOX", "EML", "EMLX", "MSG", "PST", "NSF", "ZIP"], id: \.self) { fmt in
                    Text(fmt)
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    #if os(iOS)
                        .background(Color(.tertiarySystemFill))
                    #else
                        .background(AppColors.backgroundSecondary)
                    #endif
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
                }
            }
        }
    }

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        HStack(spacing: Spacing.xxSmall) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.green)
            Text("On-device by default. Zero tracking. No account required.")
                .foregroundColor(.secondary)
        }
        .font(Typography.caption1)
    }

    // MARK: - Persona Switcher Sheet

    private var personaSwitcherSheet: some View {
        NavigationStack {
            List {
                ForEach(PersonaManager.Persona.pickableCases, id: \.rawValue) { p in
                    Button {
                        personaManager.switchPersona(to: p)
                        showPersonaSwitcher = false
                    } label: {
                        HStack(spacing: Spacing.small) {
                            Image(systemName: p.icon)
                                .font(.title3)
                                .foregroundColor(p.accentColor)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.primary)
                                Text(p.tagline)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if p == persona {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(p.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Switch Persona")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPersonaSwitcher = false }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 380)
        #endif
    }

    // MARK: - Feature Data Model

    private struct FeatureItem: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let tagline: String
        let color: Color
    }

    private struct FeatureCategory: Identifiable {
        var id: String { title }
        let icon: String
        let title: String
        let color: Color
        let isPrimary: Bool
        let features: [FeatureItem]
    }

    // MARK: - Persona-Ordered Categories

    private var orderedCategories: [FeatureCategory] {
        let all = [analysisCategory, forensicsCategory, securityCategory, exportCategory, aiCategory]
        let primaryOrder = personaPrimaryCategoryOrder
        var ordered: [FeatureCategory] = []
        for title in primaryOrder {
            if let cat = all.first(where: { $0.title == title }) {
                ordered.append(FeatureCategory(icon: cat.icon, title: cat.title, color: cat.color, isPrimary: true, features: cat.features))
            }
        }
        for cat in all where !primaryOrder.contains(cat.title) {
            ordered.append(cat)
        }
        return ordered
    }

    private var personaPrimaryCategoryOrder: [String] {
        switch persona {
        case .forensic:   return ["Forensics & Legal", "Security & Detection"]
        case .legal:      return ["Forensics & Legal", "Analysis & Insights"]
        case .itAdmin:    return ["Security & Detection", "Analysis & Insights"]
        case .journalist: return ["AI Intelligence", "Analysis & Insights"]
        case .personal:   return ["AI Intelligence", "Export & Reports"]
        case .general:    return ["Analysis & Insights", "AI Intelligence"]
        }
    }

    // MARK: - Feature Categories

    private var analysisCategory: FeatureCategory {
        FeatureCategory(icon: "chart.bar.xaxis", title: "Analysis & Insights", color: .blue, isPrimary: false, features: [
            FeatureItem(icon: "magnifyingglass", name: "Smart Search", tagline: "Boolean, regex, proximity", color: .blue),
            FeatureItem(icon: "chart.xyaxis.line", name: "Visual Analytics", tagline: "Charts, trends, patterns", color: .purple),
            FeatureItem(icon: "bubble.left.and.text.bubble.right", name: "Sentiment Analysis", tagline: "Tone and emotion detection", color: .orange),
            FeatureItem(icon: "rectangle.3.group", name: "Topic Clusters", tagline: "Auto-grouped by subject", color: .teal),
            FeatureItem(icon: "calendar.day.timeline.left", name: "Email Timeline", tagline: "Chronological exploration", color: .indigo),
            FeatureItem(icon: "person.3", name: "Relationship Graph", tagline: "Who talks to whom", color: .pink),
            FeatureItem(icon: "arrow.triangle.branch", name: "Thread Summarizer", tagline: "Conversation overviews", color: .cyan),
            FeatureItem(icon: "chart.line.uptrend.xyaxis", name: "Communication Patterns", tagline: "Volume and frequency", color: .mint),
            FeatureItem(icon: "doc.on.doc", name: "Duplicate Detection", tagline: "Exact and near-matches", color: .gray),
        ])
    }

    private var forensicsCategory: FeatureCategory {
        FeatureCategory(icon: "shield.checkered", title: "Forensics & Legal", color: .orange, isPrimary: false, features: [
            FeatureItem(icon: "number.square", name: "Bates Numbering", tagline: "Legal production stamping", color: .indigo),
            FeatureItem(icon: "checkmark.seal", name: "Hash Verification", tagline: "MD5, SHA-1, SHA-256", color: .orange),
            FeatureItem(icon: "list.clipboard", name: "Audit Trail", tagline: "Tamper-evident HMAC chain", color: .brown),
            FeatureItem(icon: "link", name: "Chain of Custody", tagline: "Evidence tracking + PDF", color: .blue),
            FeatureItem(icon: "tag", name: "Evidence Tagging", tagline: "Relevant, privileged, flagged", color: .green),
            FeatureItem(icon: "text.redaction", name: "PII Redaction", tagline: "SSN, credit card, phone", color: .red),
            FeatureItem(icon: "building.columns", name: "eDiscovery Workflow", tagline: "End-to-end case management", color: .indigo),
            FeatureItem(icon: "doc.text.magnifyingglass", name: "Predictive Coding", tagline: "AI-assisted review (TAR)", color: .purple),
            FeatureItem(icon: "checklist", name: "GDPR Compliance", tagline: "Data protection reports", color: .teal),
        ])
    }

    private var securityCategory: FeatureCategory {
        FeatureCategory(icon: "shield.lefthalf.filled", title: "Security & Detection", color: .red, isPrimary: false, features: [
            FeatureItem(icon: "exclamationmark.shield", name: "Phishing Detection", tagline: "Multi-signal risk scoring", color: .red),
            FeatureItem(icon: "waveform.badge.exclamationmark", name: "Anomaly Detection", tagline: "Frequency, timing, domains", color: .orange),
            FeatureItem(icon: "eye.trianglebadge.exclamationmark", name: "PII Exposure Scan", tagline: "Find sensitive data leaks", color: .purple),
            FeatureItem(icon: "network", name: "Header Forensics", tagline: "SPF, DKIM, DMARC analysis", color: .teal),
            FeatureItem(icon: "exclamationmark.triangle", name: "IOC Extractor", tagline: "IPs, URLs, hashes, domains", color: .yellow),
            FeatureItem(icon: "bell.badge", name: "Smart Alerts", tagline: "Proactive risk notifications", color: .blue),
        ])
    }

    private var exportCategory: FeatureCategory {
        FeatureCategory(icon: "square.and.arrow.up", title: "Export & Reports", color: .green, isPrimary: false, features: [
            FeatureItem(icon: "doc.richtext", name: "PDF Export", tagline: "Print-ready documents", color: .red),
            FeatureItem(icon: "tablecells", name: "CSV / Spreadsheet", tagline: "Structured data export", color: .green),
            FeatureItem(icon: "person.text.rectangle", name: "vCard Contacts", tagline: "Extract email contacts", color: .blue),
            FeatureItem(icon: "calendar", name: "ICS Calendar", tagline: "Export meeting events", color: .orange),
            FeatureItem(icon: "doc.badge.gearshape", name: "Concordance / Relativity", tagline: "Legal load file formats", color: .indigo),
            FeatureItem(icon: "doc.zipper", name: "MSG / PST Export", tagline: "Outlook-compatible output", color: .teal),
            FeatureItem(icon: "doc.text.fill", name: "Investigation Report", tagline: "Full case report as PDF", color: .purple),
            FeatureItem(icon: "speedometer", name: "Executive Dashboard", tagline: "High-level archive overview", color: .mint),
        ])
    }

    private var aiCategory: FeatureCategory {
        FeatureCategory(icon: "sparkles", title: "AI Intelligence", color: .purple, isPrimary: false, features: [
            FeatureItem(icon: "bubble.left.and.bubble.right", name: "AI Assistant", tagline: "Ask questions about emails", color: .purple),
            FeatureItem(icon: "text.page.badge.magnifyingglass", name: "AI Email Digest", tagline: "Auto-generated summaries", color: .blue),
            FeatureItem(icon: "brain.head.profile", name: "Smart Classification", tagline: "Auto-categorize emails", color: .indigo),
            FeatureItem(icon: "tag.fill", name: "Auto-Tagger", tagline: "Intelligent label assignment", color: .orange),
            FeatureItem(icon: "gearshape.2", name: "Automation Rules", tagline: "If-then workflow engine", color: .teal),
            FeatureItem(icon: "mic", name: "Voice Assistant", tagline: "Speak to search and ask", color: .pink),
            FeatureItem(icon: "globe", name: "Translation", tagline: "Detect and translate languages", color: .cyan),
            FeatureItem(icon: "wand.and.stars", name: "Custom AI Experts", tagline: "Define your own specialists", color: .mint),
        ])
    }
}
