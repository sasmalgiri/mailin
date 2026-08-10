//
//  EmailHistoryView.swift
//  maxmailin
//
//  SAP-style "document flow" for one email: everything the archive knows
//  happened to it, in one timeline — when it was sent, when and from which
//  file it was imported, its content fingerprint, every audit-logged action,
//  evidence coding, annotations — plus its CURRENT state (labels, Bates
//  number, custodian, legal hold, review flags). Assembled entirely from
//  records the app already keeps; nothing new is collected.
//

import SwiftUI

// MARK: - Event model + pure builder (unit-tested)

struct EmailHistoryEvent: Identifiable {
    let id = UUID()
    /// Dated events form the timeline; nil-dated facts are "current state".
    let date: Date?
    let icon: String
    let title: String
    let detail: String
}

enum EmailHistoryBuilder {
    struct Inputs {
        var sentDate: Date? = nil
        var messageType: String = "received"
        var importedAt: Date? = nil
        var sourceFilename: String? = nil
        var sourceSHA256: String? = nil
        var sourceOrdinal: Int? = nil
        var contentSHA256: String? = nil
        var auditEntries: [(timestamp: Date, action: String, detail: String, examiner: String)] = []
        var annotation: (text: String, examiner: String, timestamp: Date)? = nil
        var evidenceTag: String? = nil
        var batesNumber: String? = nil
        var custodian: String? = nil
        var underLegalHold: Bool = false
        var isPinned: Bool = false
        var isRead: Bool = false
        var isArchived: Bool = false
        var isTrashed: Bool = false
        var userTags: [String] = []
        var manualLabels: [String] = []
        var removedAILabels: [String] = []
        var aiClassification: String? = nil
    }

    /// (timeline sorted oldest-first, current-state facts)
    static func build(_ i: Inputs) -> (timeline: [EmailHistoryEvent], state: [EmailHistoryEvent]) {
        var timeline: [EmailHistoryEvent] = []
        var state: [EmailHistoryEvent] = []

        if let sent = i.sentDate {
            timeline.append(EmailHistoryEvent(
                date: sent, icon: i.messageType == "sent" ? "paperplane" : "tray.and.arrow.down",
                title: i.messageType == "sent" ? "Sent" : "Received",
                detail: "The email's own date header."))
        }
        if let imported = i.importedAt {
            var detail = "Entered this archive"
            if let f = i.sourceFilename { detail += " from \(f)" }
            if let n = i.sourceOrdinal { detail += " (message #\(n + 1) in the file)" }
            if let sha = i.sourceSHA256 { detail += ". Source file SHA-256 \(sha.prefix(12))…" }
            timeline.append(EmailHistoryEvent(
                date: imported, icon: "square.and.arrow.down",
                title: "Imported", detail: detail))
        }
        if let annotation = i.annotation {
            timeline.append(EmailHistoryEvent(
                date: annotation.timestamp, icon: "note.text",
                title: "Annotated by \(annotation.examiner)", detail: annotation.text))
        }
        for entry in i.auditEntries {
            timeline.append(EmailHistoryEvent(
                date: entry.timestamp, icon: "checkmark.seal",
                title: entry.action,
                detail: entry.detail.isEmpty ? "By \(entry.examiner)" : "\(entry.detail) — by \(entry.examiner)"))
        }
        timeline.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        if let sha = i.contentSHA256 {
            state.append(EmailHistoryEvent(
                date: nil, icon: "number",
                title: "Content fingerprint",
                detail: "SHA-256 \(sha.prefix(16))… — proves the content hasn't changed since import."))
        }
        if let tag = i.evidenceTag, tag.lowercased() != "none" {
            state.append(EmailHistoryEvent(
                date: nil, icon: "tag.fill", title: "Evidence: \(tag)",
                detail: "Coding applied in forensic review."))
        }
        if let bates = i.batesNumber {
            state.append(EmailHistoryEvent(
                date: nil, icon: "number.square", title: "Bates \(bates)",
                detail: "Permanent production identifier for legal proceedings."))
        }
        if let custodian = i.custodian {
            state.append(EmailHistoryEvent(
                date: nil, icon: "person.badge.shield.checkmark", title: "Custodian: \(custodian)",
                detail: i.underLegalHold ? "Under legal hold — protected from deletion." : "Assigned custodian."))
        } else if i.underLegalHold {
            state.append(EmailHistoryEvent(
                date: nil, icon: "lock.shield", title: "Under legal hold",
                detail: "Protected from modification and deletion."))
        }
        var flags: [String] = []
        if i.isPinned { flags.append("Pinned") }
        if i.isRead { flags.append("Read") }
        if i.isArchived { flags.append("Archived") }
        if i.isTrashed { flags.append("In Trash") }
        if !flags.isEmpty {
            state.append(EmailHistoryEvent(
                date: nil, icon: "flag", title: "Review state",
                detail: flags.joined(separator: " · ")))
        }
        if !i.userTags.isEmpty {
            state.append(EmailHistoryEvent(
                date: nil, icon: "tag", title: "Your tags",
                detail: i.userTags.sorted().joined(separator: ", ")))
        }
        if !i.manualLabels.isEmpty {
            state.append(EmailHistoryEvent(
                date: nil, icon: "hand.point.up.left", title: "Manual labels",
                detail: i.manualLabels.sorted().joined(separator: ", ")))
        }
        if !i.removedAILabels.isEmpty {
            state.append(EmailHistoryEvent(
                date: nil, icon: "minus.circle", title: "AI labels you removed",
                detail: i.removedAILabels.sorted().joined(separator: ", ")))
        }
        if let classification = i.aiClassification {
            state.append(EmailHistoryEvent(
                date: nil, icon: "sparkles", title: "AI category: \(classification)",
                detail: "On-device analysis; correctable from the list."))
        }
        return (timeline, state)
    }

    /// Plain-text report of the full history (for copy/paste into case notes).
    static func report(subject: String, messageID: String?,
                       timeline: [EmailHistoryEvent], state: [EmailHistoryEvent]) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short
        var out = "EMAIL HISTORY — \(subject)\n"
        if let mid = messageID { out += "Message-ID: \(mid)\n" }
        out += "\nTIMELINE\n"
        for e in timeline {
            out += "  \(e.date.map { fmt.string(from: $0) } ?? "—")  \(e.title): \(e.detail)\n"
        }
        out += "\nCURRENT STATE\n"
        for e in state {
            out += "  \(e.title): \(e.detail)\n"
        }
        return out
    }
}

// MARK: - View

struct EmailHistoryView: View {
    let email: MBOXParser.RawEmail
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var timeline: [EmailHistoryEvent] = []
    @State private var stateFacts: [EmailHistoryEvent] = []
    @State private var isLoading = true

    private var subject: String { email.headers["Subject"] ?? "(No Subject)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Label("Email History", systemImage: "clock.arrow.circlepath")
                        .font(Typography.title2)
                    Text(subject)
                        .font(Typography.callout)
                        .lineLimit(1)
                    if let mid = email.headers["Message-ID"] {
                        Text(mid)
                            .font(Typography.monoSmall)
                            .foregroundColor(AppColors.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button {
                    PlatformClipboard.copyString(EmailHistoryBuilder.report(
                        subject: subject, messageID: email.headers["Message-ID"],
                        timeline: timeline, state: stateFacts))
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .help("Copy the complete history as text — paste it into case notes or an incident record")
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close email history")
            }
            .padding(Spacing.medium)
            Divider()

            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView("Assembling history…"); Spacer() }
                Spacer()
            } else {
                List {
                    Section("Timeline — what happened, in order") {
                        if timeline.isEmpty {
                            Text("No dated events recorded for this email yet.")
                                .foregroundColor(AppColors.secondary)
                        }
                        ForEach(timeline) { event in
                            historyRow(event, dated: true)
                        }
                    }
                    Section("Current state") {
                        if stateFacts.isEmpty {
                            Text("No labels, coding or holds on this email.")
                                .foregroundColor(AppColors.secondary)
                        }
                        ForEach(stateFacts) { event in
                            historyRow(event, dated: false)
                        }
                    }
                }
            }
        }
        .toolWindowFrame()
        .task { await load() }
    }

    private func historyRow(_ event: EmailHistoryEvent, dated: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: event.icon)
                .foregroundColor(AppColors.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.title)
                        .font(Typography.callout)
                        .fontWeight(.semibold)
                    Spacer()
                    if let date = event.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                Text(event.detail)
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func load() async {
        var inputs = EmailHistoryBuilder.Inputs()
        inputs.sentDate = SQLiteEmailStore.parsedDate(from: email.headers["Date"])
        inputs.messageType = email.messageType

        if let prov = try? await SQLiteEmailStore.shared.provenance(for: email.id) {
            inputs.importedAt = prov.importedAt
            inputs.sourceFilename = prov.sourceFilename
            inputs.sourceSHA256 = prov.sourceSHA256
            inputs.sourceOrdinal = prov.sourceOrdinal
        }

        let forensic = ForensicManager.shared
        inputs.contentSHA256 = forensic.perEmailHashes[email.id]?.sha256
        let tag = forensic.tagForEmail(email.id)
        if tag != .none { inputs.evidenceTag = tag.rawValue }
        if let note = forensic.annotations[email.id] {
            inputs.annotation = (note.text, note.examiner, note.timestamp)
        }
        // Audit entries that reference this email (by id or subject).
        let idString = email.id.uuidString
        inputs.auditEntries = forensic.auditLog
            .filter { $0.detail.contains(idString) || (!subject.isEmpty && $0.detail.contains(subject)) }
            .map { ($0.timestamp, $0.action, $0.detail, $0.examiner) }

        inputs.batesNumber = BatesNumberingManager.shared.assignments[email.id]
        inputs.custodian = CustodianManager.shared.custodian(for: email.id)
        inputs.underLegalHold = CustodianManager.shared.isUnderLegalHold(email.id)

        let review = ReviewStateService.shared
        await review.hydrateWindow(ids: [email.id])
        inputs.isPinned = review.isPinned(email.id)
        inputs.isRead = review.isRead(email.id)
        inputs.isArchived = review.isArchived(email.id)
        inputs.isTrashed = review.isTrashed(email.id)
        inputs.userTags = Array(review.tags(for: email.id))

        inputs.manualLabels = Array(
            TagOverridePersistence.load(key: TagOverridePersistence.manualKey)[email.id] ?? [])
        inputs.removedAILabels = Array(
            TagOverridePersistence.load(key: TagOverridePersistence.suppressedKey)[email.id] ?? [])

        let built = EmailHistoryBuilder.build(inputs)
        timeline = built.timeline
        stateFacts = built.state
        isLoading = false
    }
}
