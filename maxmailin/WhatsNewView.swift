import SwiftUI

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastSeenVersion") private var lastSeenVersion = ""

    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    ForEach(releaseNotes, id: \.version) { release in
                        releaseSection(release)
                    }
                }
                .padding(Spacing.large)
            }
            footer
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 400, idealHeight: 560)
        #endif
        .onAppear { lastSeenVersion = currentVersion }
    }

    private var header: some View {
        VStack(spacing: Spacing.small) {
            PlatformApp.appIconImage
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)

            Text("What's New in mailin")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)

            Text("Version \(currentVersion)")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
        }
        .padding(.top, Spacing.large)
        .padding(.bottom, Spacing.medium)
    }

    private var footer: some View {
        VStack(spacing: Spacing.small) {
            Divider()
            Button("Continue") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(Spacing.medium)
        }
    }

    private func releaseSection(_ release: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("v\(release.version)")
                    .font(Typography.headline)
                    .fontWeight(.bold)
                if release.version == currentVersion {
                    Text("Current")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppColors.primary)
                        .cornerRadius(4)
                }
                Spacer()
                Text(release.date)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }

            ForEach(release.items, id: \.title) { item in
                HStack(alignment: .top, spacing: Spacing.small) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14))
                        .foregroundColor(item.color)
                        .frame(width: 24, height: 24)
                        .background(item.color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(Typography.callout)
                            .fontWeight(.medium)
                        Text(item.description)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundSecondary.opacity(0.5))
        .cornerRadius(CornerRadius.medium)
    }

    static func shouldShow() -> Bool {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let lastSeen = UserDefaults.standard.string(forKey: "lastSeenVersion") ?? ""
        return lastSeen != current
    }
}

// MARK: - Data Model

private struct ReleaseNote {
    let version: String
    let date: String
    let items: [ReleaseItem]
}

private struct ReleaseItem {
    let icon: String
    let title: String
    let description: String
    let color: Color
}

// MARK: - Release Notes Content

private let releaseNotes: [ReleaseNote] = [
    ReleaseNote(version: "2.0", date: "August 2026", items: [
        ReleaseItem(icon: "infinity", title: "Million-Email Architecture", description: "Storage rebuilt on SQLite + full-text shards: browsing, search and analysis stay fast and memory stays flat whether your archive holds 1 email or 1,000,000 — measured, not estimated.", color: .blue),
        ReleaseItem(icon: "magnifyingglass.circle", title: "Complete Search Results", description: "Search now pages through every match with exact counts — no more result ceilings. Select All, bulk actions and exports cover every matching email.", color: .green),
        ReleaseItem(icon: "trash.circle", title: "Real Trash", description: "Delete now moves emails to a restorable Trash. Permanently Delete is a separate, explicit action — evidence is never destroyed by accident.", color: .red),
        ReleaseItem(icon: "person.crop.circle.badge.checkmark", title: "Automatic Setup", description: "Your email address is detected from the archive automatically — Sent/Received folders, reply statistics and sent-mail analytics work with zero configuration.", color: .indigo),
        ReleaseItem(icon: "checkmark.seal", title: "Signed Import Receipts", description: "Every import produces a cryptographically signed (HMAC) receipt. Any later modification is detectable — a forged receipt fails verification.", color: .orange),
        ReleaseItem(icon: "doc.badge.ellipsis", title: "Word Export", description: "Export any email as a Word document (.doc), alongside PDF, CSV, plain text, redacted, Bates-stamped and forensic formats.", color: .purple),
        ReleaseItem(icon: "arrow.triangle.2.circlepath", title: "Seamless Upgrade", description: "Archives from mailin 1.0 migrate automatically with exact verification — every email, tag and note accounted for, duplicates preserved.", color: .teal),
        ReleaseItem(icon: "bolt.shield", title: "Hardened Imports", description: "Streaming parsers with per-message safety ceilings, honest error reporting, and resumable checkpointed imports that survive interruption.", color: .gray),
    ]),
    ReleaseNote(version: "1.0", date: "May 2026", items: [
        ReleaseItem(icon: "envelope.arrow.triangle.branch", title: "Multi-Format Import", description: "Import MBOX, EML, EMLX, MSG, PST, OST, and NSF email archives. Drag-and-drop or use File > Open.", color: .blue),
        ReleaseItem(icon: "brain", title: "AI-Powered Analysis", description: "On-device sentiment analysis, topic classification, phishing detection, and priority scoring using Apple NLP.", color: .purple),
        ReleaseItem(icon: "shield.checkered", title: "Forensic Mode", description: "SHA-256 hash verification, evidence tagging, Bates numbering, audit logs, and chain of custody tracking.", color: .orange),
        ReleaseItem(icon: "magnifyingglass", title: "Advanced Search", description: "Boolean operators (AND/OR/NOT), regex patterns, proximity search, and full-text search across email bodies.", color: .green),
        ReleaseItem(icon: "tag", title: "Smart Tag System", description: "AI-generated tags with manual override. Click any tag to see all applicable tags and customize.", color: .teal),
        ReleaseItem(icon: "person.crop.circle", title: "Persona Profiles", description: "Choose your role (Forensic, Legal, IT Admin, Journalist, Personal) for a tailored interface.", color: .indigo),
        ReleaseItem(icon: "square.and.arrow.up", title: "Flexible Export", description: "Export to EML, MSG, PST, CSV, PDF, TIFF, vCard, ICS, and Concordance/Relativity load files.", color: .red),
        ReleaseItem(icon: "lock.shield", title: "Privacy First", description: "All processing happens on-device. Zero data collection. No cloud dependency.", color: .gray),
    ]),
]
