//
//  AboutView.swift
//  mailin
//
//  Professional About window following Apple design standards
//

import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.medium) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
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

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    featureRow(
                        icon: "gift.fill",
                        title: "Free to Try, Flexible Upgrade",
                        description: "Monthly, yearly, or lifetime — choose the plan that works for you."
                    )
                    featureRow(
                        icon: "lock.shield.fill",
                        title: "Complete Privacy",
                        description: "Zero data collection. Zero cloud. Everything stays on your device."
                    )
                    featureRow(
                        icon: "apple.logo",
                        title: "Native Apple Technology",
                        description: "Built with SwiftUI and on-device AI. Fast, fluid, and truly native."
                    )
                    featureRow(
                        icon: "brain.head.profile",
                        title: "On-Device AI",
                        description: "Sentiment analysis, topics, entities, and language detection — all offline."
                    )
                    featureRow(
                        icon: "envelope.open.fill",
                        title: "Advanced Parsing",
                        description: "RFC 822 & MIME compliant. Google Takeout, Thunderbird, Apple Mail ready."
                    )
                    featureRow(
                        icon: "chart.bar.fill",
                        title: "Reply Analytics",
                        description: "Track communication patterns, reply frequency, and conversation threads."
                    )
                }
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.medium)
            }

            Divider()

            VStack(spacing: Spacing.small) {
                HStack(spacing: Spacing.medium) {
                    if let privacyURL = URL(string: "https://sasmalgiri.github.io/mailin/privacy") {
                        Link("Privacy Policy", destination: privacyURL)
                            .font(Typography.caption1)
                    }
                    if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                        Link("Terms of Use", destination: termsURL)
                            .font(Typography.caption1)
                    }
                }

                Button("Contact Support") {
                    guard let url = URL(string: "mailto:sasmalgiri@gmail.com") else { return }
                    openURL(url)
                }
                .buttonStyle(.link)

                Text("\u{00A9} 2025-2026 mailin. All rights reserved.")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.vertical, Spacing.medium)
        }
        .frame(width: 400, height: 500)
        .background(AppColors.backgroundPrimary)
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: icon)
                .font(Typography.title2)
                .foregroundStyle(
                    .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
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
}

#Preview {
    AboutView()
}
