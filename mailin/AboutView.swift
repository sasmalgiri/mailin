//
//  AboutView.swift
//  mailin
//
//  Professional About window following Apple design standards
//

import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var showLegalSheet: LegalSheet?

    private enum LegalSheet: String, Identifiable {
        case privacy, terms, licenses, forensic, accessibility
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.medium) {
                PlatformApp.appIconImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.1), radius: Shadows.large.radius, y: Shadows.large.y)

                VStack(spacing: Spacing.xxSmall) {
                    Text("mailin")
                        .font(Typography.largeTitle)

                    Text("Email Archive Analyzer")
                        .font(Typography.headline)
                        .foregroundColor(AppColors.secondary)
                }

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
            }
            .padding(.top, Spacing.xLarge)
            .padding(.bottom, Spacing.large)
            .adaptiveHeroBackground(colors: [.blue, .purple, .indigo, .cyan])

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    featureRow(
                        icon: "gift.fill",
                        title: "Free to Try, Flexible Upgrade",
                        description: "Monthly or yearly — choose the plan that works for you."
                    )
                    featureRow(
                        icon: "lock.shield.fill",
                        title: "Privacy First",
                        description: "Zero data collection. On-device by default. Cloud AI is optional and user-controlled."
                    )
                    featureRow(
                        icon: "swift",
                        title: "Native Apple Technology",
                        description: "Built with SwiftUI and on-device AI. Fast, fluid, and truly native."
                    )
                    featureRow(
                        icon: "brain.head.profile",
                        title: "Hybrid AI — On-Device + Cloud",
                        description: "MoE expert pipeline with Apple Intelligence, NLP, and optional OpenAI/Anthropic cloud AI."
                    )
                    featureRow(
                        icon: "envelope.open.fill",
                        title: "7 Format Support",
                        description: "MBOX, EML, EMLX, MSG, PST, OST, NSF — Gmail, Outlook, Thunderbird, Apple Mail, Lotus Notes."
                    )
                    featureRow(
                        icon: "paperplane.fill",
                        title: "Send & Receive Email",
                        description: "IMAP fetch, SMTP send with retry, signatures, and Gmail/Outlook cloud connect."
                    )
                    featureRow(
                        icon: "chart.bar.fill",
                        title: "Analytics Dashboard",
                        description: "Volume timelines, top contacts, heatmaps, network graphs, and exportable reports."
                    )
                }
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.medium)
                .adaptiveCard(cornerRadius: CornerRadius.large)
            }

            Divider()

            VStack(spacing: Spacing.small) {
                HStack(spacing: Spacing.medium) {
                    Button("Privacy Policy") { showLegalSheet = .privacy }
                        .font(Typography.caption1)
                    Button("Terms of Use") { showLegalSheet = .terms }
                        .font(Typography.caption1)
                    Button("Licenses") { showLegalSheet = .licenses }
                        .font(Typography.caption1)
                }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif

                HStack(spacing: Spacing.medium) {
                    Button("Forensic Disclaimer") { showLegalSheet = .forensic }
                        .font(Typography.caption2)
                    Button("Accessibility") { showLegalSheet = .accessibility }
                        .font(Typography.caption2)
                }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif

                Button("Contact Support") {
                    guard let url = URL(string: "mailto:sasmalgiri@gmail.com") else { return }
                    openURL(url)
                }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif

                Text("\u{00A9} 2025-2026 mailin. All rights reserved.")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.vertical, Spacing.medium)
        }
        #if os(macOS)
        .frame(width: 400, height: 560)
        #endif
        .background(AppColors.backgroundPrimary)
        .sheet(item: $showLegalSheet) { sheet in
            legalSheetContent(sheet)
        }
    }

    @ViewBuilder
    private func legalSheetContent(_ sheet: LegalSheet) -> some View {
        NavigationStack {
            ScrollView {
                Text(textForSheet(sheet))
                    .font(.system(.caption, design: .monospaced))
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(titleForSheet(sheet))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLegalSheet = nil }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 450)
        #endif
    }

    private func titleForSheet(_ sheet: LegalSheet) -> String {
        switch sheet {
        case .privacy: return "Privacy Policy"
        case .terms: return "Terms of Use"
        case .licenses: return "Third-Party Notices"
        case .forensic: return "Forensic Disclaimer"
        case .accessibility: return "Accessibility"
        }
    }

    private func textForSheet(_ sheet: LegalSheet) -> String {
        switch sheet {
        case .privacy: return LegalComplianceManager.privacyPolicySummary
        case .terms: return LegalComplianceManager.termsOfUseSummary
        case .licenses: return LegalComplianceManager.thirdPartyNotices
        case .forensic: return LegalComplianceManager.forensicDisclaimer
        case .accessibility: return Self.accessibilityStatement
        }
    }

    private static let accessibilityStatement = """
    ACCESSIBILITY STATEMENT

    mailin is committed to providing an accessible experience for all users.

    Supported Accessibility Features:
    • VoiceOver: All interactive elements have accessibility labels and hints
    • Dynamic Type: Text scales with system font size settings
    • Keyboard Navigation: Full keyboard support on macOS and iPad with external keyboard
    • Reduce Motion: Respects system reduce motion preference
    • High Contrast: Semantic colors adapt to increased contrast settings
    • Focus Indicators: Visible focus rings on interactive elements

    Known Limitations:
    • HTML email rendering may not be fully accessible for complex email layouts
    • Some chart visualizations in Analytics may have limited VoiceOver descriptions

    If you encounter accessibility barriers, please contact us:
    sasmalgiri@gmail.com

    We are committed to improving accessibility in every release.
    """

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            featureIcon(icon)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(title)
                    .font(Typography.headline)
                Text(description)
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder
    private func featureIcon(_ name: String) -> some View {
        if #available(macOS 15, iOS 18, *) {
            Image(systemName: name)
                .font(Typography.title2)
                .foregroundStyle(
                    MeshGradient(width: 2, height: 2, points: [
                        .init(0, 0), .init(1, 0),
                        .init(0, 1), .init(1, 1)
                    ], colors: [.blue, .purple, .indigo, .cyan])
                )
        } else {
            Image(systemName: name)
                .font(Typography.title2)
                .foregroundStyle(
                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }
}

#Preview {
    AboutView()
}
