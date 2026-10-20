@testable import ArchiveCore
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
        return shouldShow(current: current, lastSeen: lastSeen)
    }

    /// Shows on a first launch, and after an update only when there are release notes the person has
    /// not seen yet (a version newer than `lastSeen`, up to `current`). A store-page-only release with no
    /// notes of its own (3.0.2) does not interrupt anyone; someone jumping from 2.0 still sees the 3.0 notes.
    static func shouldShow(current: String, lastSeen: String) -> Bool {
        guard lastSeen != current else { return false }
        guard !lastSeen.isEmpty else { return true }
        return releaseNotes.contains {
            $0.version.compare(lastSeen, options: .numeric) == .orderedDescending
                && $0.version.compare(current, options: .numeric) != .orderedDescending
        }
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
    ReleaseNote(version: "3.0.1", date: "October 2026", items: [
        ReleaseItem(icon: "checkmark.seal", title: String(localized: "Exports Say What Happened"), description: String(localized: "Every export now ends with a receipt that reports the real result — complete, limited by the Free plan, cancelled, or failed with the reason. Outlook Archive (.pst) is in every Export menu, on iPhone and iPad too."), color: .green),
        ReleaseItem(icon: "iphone.gen3", title: String(localized: "iPhone and iPad Fixes"), description: String(localized: "Duplicates, Topics and the PII Report work on iPhone, Tools ▸ Export offers every format, and iPad search filters the list as you type."), color: .blue),
        ReleaseItem(icon: "person.crop.circle.badge.checkmark", title: String(localized: "Clearer Free Plan"), description: String(localized: "The Free plan works with the newest 500 emails of your archive; lists and searches now show how many of their emails that covers."), color: .orange),
    ]),
    ReleaseNote(version: "3.0", date: "October 2026", items: [
        ReleaseItem(icon: "arrow.counterclockwise.circle", title: String(localized: "Find Deleted Mail"), description: String(localized: "Mail that was deleted but is still inside your Outlook, Thunderbird, Apple Mail or Gmail files is marked, with how it was found. Deep recovery searches the free space of Outlook files."), color: .orange),
        ReleaseItem(icon: "doc.text.viewfinder", title: String(localized: "Search Scanned Attachments"), description: String(localized: "Scanned PDFs and photos are read on this device, so in:attachments finds the words inside them."), color: .teal),
        ReleaseItem(icon: "curlybraces", title: String(localized: "Scripts and Shortcuts"), description: String(localized: "Tag, set aside, note and number emails with scripts that run with no network access, after a dry run that shows every change. Shortcuts can do the same."), color: .indigo),
        ReleaseItem(icon: "shippingbox", title: String(localized: "Review Together"), description: String(localized: "Send emails to a reviewer as a Review Pack and merge the answers, or run a team case with signed logs and second-level review. Reviewers need no purchase."), color: .purple),
        ReleaseItem(icon: "clock.badge.checkmark", title: String(localized: "Hidden Timestamps"), description: String(localized: "Read the time values Gmail and other systems keep in message headers, and check DKIM and ARC signatures."), color: .brown),
        ReleaseItem(icon: "archivebox", title: String(localized: "Outlook PST Export, Rebuilt"), description: String(localized: "PST files are written to Microsoft's published format — folders, recipients and attachments — and open in Outlook."), color: .blue),
        ReleaseItem(icon: "tray.and.arrow.up", title: String(localized: "Works with DEVONthink"), description: String(localized: "On the Mac, Send to DEVONthink hands emails over as standard .eml files, and Copy Link to Email gives a link that reopens the email from any app."), color: .gray),
        ReleaseItem(icon: "text.bubble", title: String(localized: "Answers with Sources"), description: String(localized: "Every AI answer lists the emails it came from; counts, dates and amounts are read from your archive, not written by the model."), color: .pink),
        ReleaseItem(icon: "globe", title: String(localized: "11 Languages"), description: String(localized: "The whole interface is available in English, German, Spanish, French, Hindi, Italian, Japanese, Korean, Brazilian Portuguese, and Simplified and Traditional Chinese."), color: .green),
        ReleaseItem(icon: "sidebar.left", title: String(localized: "Three-Pane Archive"), description: String(localized: "Mailboxes, sources and labels on the left, the list in the middle, the message on the right. Open an archive and you are in it. Keyboard-first: J/K, Return, / to search."), color: .blue),
        ReleaseItem(icon: "list.bullet.rectangle", title: String(localized: "Import Queue"), description: String(localized: "Pause, resume, reorder or stop a single file while the rest continue. Choose the duplicate policy and attachment indexing before you start. Every import ends in a signed receipt."), color: .indigo),
        ReleaseItem(icon: "square.and.arrow.up.on.square", title: String(localized: "Export Pre-flight and Resume"), description: String(localized: "See the space needed first. Every export ends in a receipt with its hash; an interrupted export resumes from that receipt and writes nothing twice."), color: .green),
        ReleaseItem(icon: "externaldrive", title: String(localized: "Move the Archive"), description: String(localized: "Copy the archive to another disk, verified, and open it from there. If the disk is away, the copy on this device stays usable. Nothing is deleted until the new location is live."), color: .teal),
        ReleaseItem(icon: "magnifyingglass.circle", title: String(localized: "Search That Says What It Saw"), description: String(localized: "Results show where they matched (From, Subject, Body, Attachment) and how much of the archive the index covered when it answered."), color: .orange),
        ReleaseItem(icon: "doc.zipper", title: String(localized: "Large Messages and ZIPs"), description: String(localized: "Single messages over 100 MB are archived and read from the file you imported instead of being reported as damaged. Import a ZIP directly."), color: .purple),
        ReleaseItem(icon: "square.grid.2x2", title: String(localized: "Optional Pages"), description: String(localized: "AI Insights and Professional Workflows are separate pages, off until you switch them on. Nothing they need runs until you do."), color: .pink),
        // The 3.0 engines were promoted (on by default); each is still a switch in Settings ▸ Modules.
        ReleaseItem(icon: "square.stack.3d.up.fill", title: String(localized: "Whole-Archive Tools"), description: String(localized: "Legal, analysis and AI tools work on every email in your archive instead of the newest 2,000 — with progress, Cancel and resume after an interruption."), color: .mint),
        ReleaseItem(icon: "lifepreserver", title: String(localized: "Crash-Proof Engines"), description: String(localized: "If the app ever stops inside a new engine, that engine switches itself off at the next launch and the previous one takes over. Snapshots before every upgrade, Safe Mode after repeated stops, and a Health page in Settings."), color: .red),
        ReleaseItem(icon: "checkmark.seal.fill", title: String(localized: "Provable Results"), description: String(localized: "Whole-archive jobs record exactly which emails they covered; Re-run and prove checks the same scope still gives the same emails. Evidence records, BagIt preservation packages and Bates numbers that never change."), color: .brown),
        ReleaseItem(icon: "checkmark.shield", title: String(localized: "Hardened Integrity"), description: String(localized: "The audit log is anchored so a truncated log is detected; a large message whose source file changed since import is refused rather than exported silently."), color: .gray),
    ]),
    ReleaseNote(version: "2.0", date: "August 2026", items: [
        ReleaseItem(icon: "infinity", title: "Million-Email Architecture", description: "Storage rebuilt on SQLite + full-text shards: browsing, search and analysis stay fast and memory stays flat whether your archive holds 1 email or 1,000,000 — measured, not estimated.", color: .blue),
        ReleaseItem(icon: "magnifyingglass.circle", title: String(localized: "Complete Search Results"), description: String(localized: "Search now pages through every match with exact counts — no more result ceilings. Select All, bulk actions and exports cover every matching email."), color: .green),
        ReleaseItem(icon: "trash.circle", title: String(localized: "Real Trash"), description: String(localized: "Delete now moves emails to a restorable Trash. Permanently Delete is a separate, explicit action — evidence is never destroyed by accident."), color: .red),
        ReleaseItem(icon: "person.crop.circle.badge.checkmark", title: String(localized: "Automatic Setup"), description: String(localized: "Your email address is detected from the archive automatically — Sent/Received folders, reply statistics and sent-mail analytics work with zero configuration."), color: .indigo),
        ReleaseItem(icon: "checkmark.seal", title: String(localized: "Signed Import Receipts"), description: String(localized: "Every import produces a cryptographically signed (HMAC) receipt. Any later modification is detectable — a forged receipt fails verification."), color: .orange),
        ReleaseItem(icon: "doc.badge.ellipsis", title: String(localized: "Word Export"), description: String(localized: "Export any email as a Word document (.doc), alongside PDF, CSV, plain text, redacted, Bates-stamped and forensic formats."), color: .purple),
        ReleaseItem(icon: "arrow.triangle.2.circlepath", title: String(localized: "Seamless Upgrade"), description: String(localized: "Archives from mailin 1.0 migrate automatically with exact verification — every email, tag and note accounted for, duplicates preserved."), color: .teal),
        ReleaseItem(icon: "bolt.shield", title: String(localized: "Hardened Imports"), description: String(localized: "Streaming parsers with per-message safety ceilings, honest error reporting, and resumable checkpointed imports that survive interruption."), color: .gray),
    ]),
    ReleaseNote(version: "1.0", date: "May 2026", items: [
        ReleaseItem(icon: "envelope.arrow.triangle.branch", title: String(localized: "Multi-Format Import"), description: String(localized: "Import MBOX, EML, EMLX, MSG, PST, OST, and NSF email archives. Drag-and-drop or use File > Open."), color: .blue),
        ReleaseItem(icon: "brain", title: String(localized: "AI-Powered Analysis"), description: String(localized: "On-device sentiment analysis, topic classification, phishing detection, and priority scoring using Apple NLP."), color: .purple),
        ReleaseItem(icon: "shield.checkered", title: String(localized: "Forensic Mode"), description: String(localized: "SHA-256 hash verification, evidence tagging, Bates numbering, audit logs, and chain of custody tracking."), color: .orange),
        ReleaseItem(icon: "magnifyingglass", title: String(localized: "Advanced Search"), description: String(localized: "Boolean operators (AND/OR/NOT), regex patterns, proximity search, and full-text search across email bodies."), color: .green),
        ReleaseItem(icon: "tag", title: String(localized: "Smart Tag System"), description: String(localized: "AI-generated tags with manual override. Click any tag to see all applicable tags and customize."), color: .teal),
        ReleaseItem(icon: "person.crop.circle", title: String(localized: "Persona Profiles"), description: String(localized: "Choose your role (Forensic, Legal, IT Admin, Journalist, Personal) for a tailored interface."), color: .indigo),
        ReleaseItem(icon: "square.and.arrow.up", title: String(localized: "Flexible Export"), description: String(localized: "Export to EML, MSG, PST, CSV, PDF, TIFF, vCard, ICS, and Concordance/Relativity load files."), color: .red),
        ReleaseItem(icon: "lock.shield", title: String(localized: "Privacy First"), description: String(localized: "All processing happens on-device. Zero data collection. No cloud dependency."), color: .gray),
    ]),
]
