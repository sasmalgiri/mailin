@testable import ArchiveCore
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
            case .available: return String(localized: "Included")
            case .requiresProfessional: return String(localized: "Professional")
            case .notInThisBuild: return String(localized: "Not in this build")
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
                .init(name: String(localized: "Import mail"), detail: String(localized: "mbox, eml, emlx, msg, pst, ost, nsf — routed by file content, not by filename"), availability: .available),
                .init(name: String(localized: "Read messages"), detail: String(localized: "Headers, body, raw MIME, and attachments opened or saved from the archive"), availability: .available),
                .init(name: String(localized: "Search"), detail: String(localized: "Sender, recipients, subject and body, with a visible index-coverage count"), availability: .available),
                .init(name: String(localized: "Export"), detail: String(localized: "mbox, eml, CSV, JSON, PDF and more, with a hash and a receipt"), availability: .available),
                .init(name: String(localized: "Import receipts"), detail: String(localized: "Source SHA-256, full accounting, and a Complete / Partial / Failed verdict"), availability: .available),
                .init(name: String(localized: "Duplicates & attachments"), detail: String(localized: "Duplicate manager, attachment gallery and timeline over the archive"), availability: .available),
            ]
        case .aiInsights:
            return [
                .init(name: String(localized: "Ask questions"), detail: String(localized: "Answers cite the exact messages they came from, and every citation reopens the original"), availability: .available),
                .init(name: String(localized: "Summaries & digests"), detail: String(localized: "Summarise a selection, a conversation or a search result"), availability: .available),
                .init(name: String(localized: "Anomaly detection"), detail: String(localized: "Unusual sending times, frequency spikes and new domains"), availability: .available),
                .init(name: String(localized: "Auto-tagging"), detail: String(localized: "Suggested tags over the archive"), availability: .available),
                .init(name: String(localized: "Predictive coding"), detail: String(localized: "Learns from your tagging to rank documents for review"), availability: .requiresProfessional),
                .init(name: String(localized: "Topic clusters"), detail: String(localized: "Groups the archive by topic"), availability: .available),
                .init(name: String(localized: "Keyword monitor"), detail: String(localized: "Flags messages containing terms you choose"), availability: .available),
            ]
        case .professional:
            return [
                .init(name: String(localized: "Job catalog"), detail: String(localized: "51 built-in workflows across forensic, legal, IT, journalist, researcher and personal work"), availability: .available),
                .init(name: String(localized: "Cases & custodians"), detail: String(localized: "Case intake, custodian records and collection scope"), availability: .requiresProfessional),
                .init(name: String(localized: "Legal hold"), detail: String(localized: "Held messages cannot be deleted, and the hold survives switching this page off"), availability: .requiresProfessional),
                .init(name: String(localized: "Review batches"), detail: String(localized: "Organise messages into batches for systematic review"), availability: .requiresProfessional),
                .init(name: String(localized: "Bates numbering & redaction"), detail: String(localized: "Sequential stamping and person redaction with a validation pass"), availability: .requiresProfessional),
                .init(name: String(localized: "Chain of custody & audit trail"), detail: String(localized: "Tamper-evident HMAC chain of who did what, when"), availability: .requiresProfessional),
                .init(name: String(localized: "Reasoning studios"), detail: String(localized: "ACH hypothesis matrix, fact–evidence matrix, evidence desks, action register"), availability: .available),
                .init(name: String(localized: "Productions"), detail: String(localized: "Numbered documents, hash manifests and delivery-ready exports"), availability: .requiresProfessional),
            ]
        case .liveMail:
            return [
                .init(name: String(localized: "Add mail accounts"), detail: String(localized: "Gmail, Microsoft 365 or standards-based IMAP + SMTP"), availability: .notInThisBuild),
                .init(name: String(localized: "Receive mail"), detail: String(localized: "Headers first, bodies on demand, with per-account limits"), availability: .notInThisBuild),
                .init(name: String(localized: "Send mail"), detail: String(localized: "Compose, reply, forward, drafts and a per-account outbox"), availability: .notInThisBuild),
                .init(name: String(localized: "Copy to Archive"), detail: String(localized: "Explicitly copy or reference live messages into the archive"), availability: .notInThisBuild),
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
                "Uses the on-device model only. No cloud provider is ever contacted; the app has no network access.",
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
        #if os(macOS)
        // A Mac sheet sizes itself from this. On iOS the sheet is the
        // screen's width; a 520 pt minimum pushed the content past both
        // edges of an iPhone (found 2026-10-09: "Not now" read "ow").
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 560)
        #endif
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
            return String(localized: "Import, read, search and export your mail. Always available.")
        case .aiInsights:
            return String(localized: "Ask questions about the archive and build reports, with every answer citing the messages it came from.")
        case .professional:
            return String(localized: "Case work: intake, custodians, review, productions and a tamper-evident audit trail.")
        case .liveMail:
            return String(localized: "Connect mail accounts to send and receive, kept separate from your archive.")
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
