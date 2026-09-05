import SwiftUI

struct PersonaPickerHomeView: View {
    @ObservedObject private var personaManager = PersonaManager.shared
    let onSelectPersona: (PersonaManager.Persona) -> Void

    /// Power-user personas tucked behind a collapsed disclosure. Personal is
    /// promoted as the default workspace so the picker stays uncluttered.
    @State private var showAdvancedPersonas: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.medium),
        GridItem(.flexible(), spacing: Spacing.medium),
    ]

    private var advancedPersonas: [PersonaManager.Persona] {
        [.forensic, .legal, .itAdmin, .journalist]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.large) {
                headerSection
                personaGrid
                currentPersonaBanner
                privacyTagline
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
        }
        .background(AppColors.backgroundPrimary)
        .onAppear {
            // Expand automatically if the user is already on a power persona,
            // so their current choice is visible.
            if advancedPersonas.contains(personaManager.selectedPersona) {
                showAdvancedPersonas = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: Spacing.xSmall) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 40))
                .foregroundStyle(
                    .linearGradient(colors: [.blue, .purple, .orange],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("mailin")
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)
            Text("Choose your workspace")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, Spacing.medium)
    }

    // MARK: - Persona Grid

    private var personaGrid: some View {
        VStack(spacing: Spacing.medium) {
            // Personal is the default, always visible.
            personaCard(.personal)

            // Power-user personas are collapsed by default to keep the
            // picker simple. Users can expand to switch workspaces.
            DisclosureGroup(isExpanded: $showAdvancedPersonas) {
                LazyVGrid(columns: columns, spacing: Spacing.medium) {
                    ForEach(advancedPersonas, id: \.self) { persona in
                        personaCard(persona)
                    }
                }
                .padding(.top, Spacing.small)
            } label: {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "rectangle.stack.person.crop")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Other workspaces")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text("Forensic · Legal · IT · Journalist")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, Spacing.small)
            .accessibilityHint("Expand to choose a specialized workspace")
        }
    }

    private func personaCard(_ persona: PersonaManager.Persona) -> some View {
        let isSelected = personaManager.selectedPersona == persona
        return Button { onSelectPersona(persona) } label: {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.small) {
                    ZStack {
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .fill(
                                LinearGradient(colors: [persona.accentColor, persona.accentColor.opacity(0.6)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: persona.icon)
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(persona.shortLabel)
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        Text(persona.displayName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(persona.accentColor)
                    }
                }

                Text(persona.tagline)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(featuresForPersona(persona), id: \.title) { feature in
                        HStack(spacing: 6) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 10))
                                .foregroundColor(persona.accentColor)
                                .frame(width: 14)
                            Text(feature.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .fill(isSelected ? persona.accentColor.opacity(0.06) : AppColors.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .strokeBorder(isSelected ? persona.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(persona.displayName) persona")
    }

    // MARK: - Current Persona Banner

    private var currentPersonaBanner: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: personaManager.selectedPersona.icon)
                .font(.system(size: 14))
                .foregroundColor(personaManager.selectedPersona.accentColor)
            Text("Current: **\(personaManager.selectedPersona.displayName)**")
                .font(.system(size: 12))
            Spacer()
            Text("Tap a card to switch")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium)
                .fill(personaManager.selectedPersona.accentColor.opacity(0.06))
        )
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

    // MARK: - Per-Persona Features

    private struct FeatureItem: Hashable {
        let icon: String
        let title: String
    }

    private func featuresForPersona(_ persona: PersonaManager.Persona) -> [FeatureItem] {
        switch persona {
        case .forensic:
            return [
                FeatureItem(icon: "shield.checkered", title: "Evidence coding & review"),
                FeatureItem(icon: "link", title: "Chain of custody tracking"),
                FeatureItem(icon: "exclamationmark.shield", title: "IOC & threat detection"),
                FeatureItem(icon: "waveform.path.ecg", title: "Anomaly detection"),
                FeatureItem(icon: "doc.text.magnifyingglass", title: "Investigation reports"),
            ]
        case .legal:
            return [
                FeatureItem(icon: "building.columns", title: "Privilege review workspace"),
                FeatureItem(icon: "checklist", title: "eDiscovery EDRM workflow"),
                FeatureItem(icon: "number", title: "Bates numbering & production"),
                FeatureItem(icon: "hand.raised", title: "GDPR compliance reports"),
                FeatureItem(icon: "brain", title: "Predictive coding / TAR"),
            ]
        case .itAdmin:
            return [
                FeatureItem(icon: "server.rack", title: "Header & MIME analysis"),
                FeatureItem(icon: "checkmark.shield", title: "SPF / DKIM / DMARC auth"),
                FeatureItem(icon: "arrow.triangle.swap", title: "Routing hop inspection"),
                FeatureItem(icon: "globe", title: "Domain mismatch detection"),
                FeatureItem(icon: "chart.bar", title: "Batch auth statistics"),
            ]
        case .journalist:
            return [
                FeatureItem(icon: "newspaper", title: "Source & lead tracking"),
                FeatureItem(icon: "calendar.day.timeline.left", title: "Event timeline builder"),
                FeatureItem(icon: "text.quote", title: "Key quote extraction"),
                FeatureItem(icon: "person.2", title: "Contact network mapping"),
                FeatureItem(icon: "circle.grid.3x3", title: "Topic discovery & clusters"),
            ]
        case .researcher:
            return [
                FeatureItem(icon: "books.vertical", title: "Research protocol on record"),
                FeatureItem(icon: "checklist", title: "Screening — include / exclude"),
                FeatureItem(icon: "tag", title: "Extraction & coding (codebook)"),
                FeatureItem(icon: "calendar.day.timeline.left", title: "Cited chronologies"),
                FeatureItem(icon: "brain.head.profile", title: "Reasoning studio & source criticism"),
            ]
        case .personal:
            return [
                FeatureItem(icon: "tray.full", title: "Smart email categories"),
                FeatureItem(icon: "person.crop.circle", title: "Contact insights & stats"),
                FeatureItem(icon: "paperclip", title: "Attachment browser"),
                FeatureItem(icon: "doc.on.doc", title: "Duplicate cleanup"),
                FeatureItem(icon: "text.bubble", title: "Thread summarizer"),
            ]
        case .general:
            return [
                FeatureItem(icon: "sparkles", title: "AI assistant & digest"),
                FeatureItem(icon: "chart.bar", title: "Full analytics suite"),
                FeatureItem(icon: "point.3.connected.trianglepath.dotted", title: "Knowledge graph explorer"),
                FeatureItem(icon: "chart.line.uptrend.xyaxis", title: "Predictive insights"),
                FeatureItem(icon: "puzzlepiece.extension", title: "Plugin extensibility"),
            ]
        }
    }
}

#Preview {
    PersonaPickerHomeView { _ in }
        .frame(width: 720, height: 800)
}
