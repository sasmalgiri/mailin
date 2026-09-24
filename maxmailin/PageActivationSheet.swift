//
//  PageActivationSheet.swift
//  mailin
//
//  Clicking an inactive page tab asks first, and shows exactly what that page
//  contains before the user decides (directive §1: "shows explicit pending
//  work, data retention and purchase requirement; does not silently enable
//  paid features").
//
//  Honesty rules the matrix follows:
//   • a feature that is not built in this version says so, in its own row
//   • a feature that needs a purchase says so, and enabling the page does not
//     grant it
//   • what the page will START DOING once enabled is listed separately from
//     what it lets you do, because that is the part that costs the user
//     something (background work, a model download, network access)
//

import SwiftUI

// MARK: - Catalog

/// One capability of a page, with an honest availability state.
struct PageFeature: Identifiable, Sendable {
    enum Availability: Sendable, Equatable {
        case available
        case requiresProfessional
        case notInThisBuild

        var label: String {
            switch self {
            case .available: return "Included"
            case .requiresProfessional: return "Professional"
            case .notInThisBuild: return "Not in this build"
            }
        }

        var color: Color {
            switch self {
            case .available: return .green
            case .requiresProfessional: return .purple
            case .notInThisBuild: return .orange
            }
        }
    }

    var id: String { name }
    let name: String
    let detail: String
    let availability: Availability
}

/// What each page offers, and what enabling it starts doing. Every row here is
/// a surface that exists in the build (or is marked as absent).
enum PageFeatureCatalog {

    static func features(for module: AppModule) -> [PageFeature] {
        switch module {
        case .archive:
            return [
                .init(name: "Import mail", detail: "mbox, eml, emlx, msg, pst, ost, nsf — routed by file content, not by filename", availability: .available),
                .init(name: "Read messages", detail: "Headers, body, raw MIME, and attachments opened or saved from the archive", availability: .available),
                .init(name: "Search", detail: "Sender, recipients, subject and body, with a visible index-coverage count", availability: .available),
                .init(name: "Export", detail: "mbox, eml, CSV, JSON, PDF and more, with a hash and a receipt", availability: .available),
                .init(name: "Import receipts", detail: "Source SHA-256, full accounting, and a Complete / Partial / Failed verdict", availability: .available),
                .init(name: "Duplicates & attachments", detail: "Duplicate manager, attachment gallery and timeline over the archive", availability: .available),
            ]
        case .aiInsights:
            return [
                .init(name: "Ask questions", detail: "Answers cite the exact messages they came from, and every citation reopens the original", availability: .available),
                .init(name: "Summaries & digests", detail: "Summarise a selection, a conversation or a search result", availability: .available),
                .init(name: "Anomaly detection", detail: "Unusual sending times, frequency spikes and new domains", availability: .available),
                .init(name: "Auto-tagging", detail: "Suggested tags over the archive", availability: .available),
                .init(name: "Predictive coding", detail: "Learns from your tagging to rank documents for review", availability: .requiresProfessional),
                .init(name: "Topic clusters", detail: "Groups the archive by topic", availability: .available),
                .init(name: "Keyword monitor", detail: "Flags messages containing terms you choose", availability: .available),
            ]
        case .professional:
            return [
                .init(name: "Job catalog", detail: "51 built-in workflows across forensic, legal, IT, journalist, researcher and personal work", availability: .available),
                .init(name: "Cases & custodians", detail: "Case intake, custodian records and collection scope", availability: .requiresProfessional),
                .init(name: "Legal hold", detail: "Held messages cannot be deleted, and the hold survives switching this page off", availability: .requiresProfessional),
                .init(name: "Review batches", detail: "Organise messages into batches for systematic review", availability: .requiresProfessional),
                .init(name: "Bates numbering & redaction", detail: "Sequential stamping and person redaction with a validation pass", availability: .requiresProfessional),
                .init(name: "Chain of custody & audit trail", detail: "Tamper-evident HMAC chain of who did what, when", availability: .requiresProfessional),
                .init(name: "Reasoning studios", detail: "ACH hypothesis matrix, fact–evidence matrix, evidence desks, action register", availability: .available),
                .init(name: "Productions", detail: "Numbered documents, hash manifests and delivery-ready exports", availability: .requiresProfessional),
            ]
        case .liveMail:
            return [
                .init(name: "Add mail accounts", detail: "Gmail, Microsoft 365 or standards-based IMAP + SMTP", availability: .notInThisBuild),
                .init(name: "Receive mail", detail: "Headers first, bodies on demand, with per-account limits", availability: .notInThisBuild),
                .init(name: "Send mail", detail: "Compose, reply, forward, drafts and a per-account outbox", availability: .notInThisBuild),
                .init(name: "Copy to Archive", detail: "Explicitly copy or reference live messages into the archive", availability: .notInThisBuild),
            ]
        }
    }

    /// What the page begins doing once enabled — the cost side of the decision.
    static func consequences(for module: AppModule) -> [String] {
        switch module {
        case .archive:
            return []
        case .aiInsights:
            return [
                "Runs analysis in the background and keeps a weekly digest schedule.",
                "Uses the on-device model. A cloud provider is never contacted unless you separately opt in per request.",
                "Switching it off stops the work and unloads the model; saved summaries and reports are kept.",
            ]
        case .professional:
            return [
                "Seeds the workflow catalog and starts the tamper-evident audit chain.",
                "The audit chain records that it begins now — earlier activity is evidenced by import receipts only.",
                "Switching it off hides the page but keeps cases, custodians, holds and documents. No hold is ever lifted.",
            ]
        case .liveMail:
            return [
                "Nothing in this build: no account can be added and no mail server is contacted.",
                "When it ships, enabling it alone still connects to nothing — each account is authorised separately by you.",
            ]
        }
    }
}

// MARK: - Sheet

struct PageActivationSheet: View {
    let module: AppModule
    let activation: ModuleActivation
    let hasProfessional: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void

    private var features: [PageFeature] { PageFeatureCatalog.features(for: module) }
    private var consequences: [String] { PageFeatureCatalog.consequences(for: module) }

    private var isLocked: Bool {
        if case .unavailable = activation { return true }
        return false
    }

    private var lockReason: String? {
        if case .unavailable(let reason) = activation { return reason }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            // Header and buttons stay put; only the matrix scrolls, so the
            // decision controls are never pushed off a small window.
            header

            if let lockReason {
                Label("This page is \(lockReason). It cannot be turned on here.",
                      systemImage: "lock.fill")
                    .font(Typography.callout)
                    .foregroundColor(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    matrix

                    if !consequences.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text("What happens when you turn it on")
                                .font(Typography.headline)
                            ForEach(consequences, id: \.self) { line in
                                Label(line, systemImage: "arrow.turn.down.right")
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Divider()
            buttons
        }
        .padding(Spacing.large)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn on \(module.displayName)?")
                    .font(Typography.title3)
                Text(purpose)
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The feature matrix: what you get, and on what terms.
    private var matrix: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Feature").font(Typography.caption2).foregroundColor(AppColors.secondary)
                Spacer()
                Text("Availability").font(Typography.caption2).foregroundColor(AppColors.secondary)
            }
            .padding(.bottom, 4)
            Divider()

            ForEach(features) { feature in
                HStack(alignment: .top, spacing: Spacing.small) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.name).font(Typography.callout)
                        Text(feature.detail)
                            .font(Typography.caption2)
                            .foregroundColor(AppColors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Spacing.small)
                    Text(feature.availability.label)
                        .font(Typography.caption2)
                        .foregroundColor(feature.availability.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(feature.availability.color.opacity(0.12),
                                    in: Capsule())
                }
                .padding(.vertical, 6)
                Divider()
            }

            if features.contains(where: { $0.availability == .requiresProfessional }), !hasProfessional {
                Text("Turning this page on does not purchase anything. Rows marked Professional stay locked until you upgrade.")
                    .font(Typography.caption2)
                    .foregroundColor(.purple)
                    .padding(.top, 6)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("Not now", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Turn on \(module.displayName)", action: onEnable)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isLocked)
        }
    }

    private var icon: String {
        switch module {
        case .archive: return "archivebox"
        case .aiInsights: return "sparkles"
        case .professional: return "briefcase"
        case .liveMail: return "envelope.badge"
        }
    }

    private var purpose: String {
        switch module {
        case .archive:
            return "Import, read, search and export your mail. Always available."
        case .aiInsights:
            return "Ask questions about the archive and build reports, with every answer citing the messages it came from."
        case .professional:
            return "Case work: intake, custodians, review, productions and a tamper-evident audit trail."
        case .liveMail:
            return "Connect mail accounts to send and receive, kept separate from your archive."
        }
    }
}

#if DEBUG
#Preview("Activate AI Insights") {
    PageActivationSheet(
        module: .aiInsights,
        activation: .disabled,
        hasProfessional: false,
        onEnable: {}, onCancel: {}
    )
}

#Preview("Activate Live Mail — not built") {
    PageActivationSheet(
        module: .liveMail,
        activation: .disabled,
        hasProfessional: true,
        onEnable: {}, onCancel: {}
    )
}
#endif
