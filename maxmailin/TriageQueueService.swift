//
//  TriageQueueService.swift
//  maxmailin
//
//  The IT admin's phishing triage intake. Users forward suspicious emails
//  into a watched folder; this service is the listener the watch folder
//  posts to — it persists the new emails (Message-ID deduped), stamps them
//  `triage:pending`, and audit-logs the intake. The queue is then a plain
//  SQL tag query; issuing a verdict swaps the tag and logs it.
//

import Foundation

/// Verdict vocabulary. Tags are SQL-backed user tags — no new schema.
enum TriageVerdict: String, CaseIterable {
    case confirmedPhishing = "triage:confirmed-phishing"
    case safe = "triage:safe"
    case needsInfo = "triage:needs-info"

    static let pendingTag = "triage:pending"

    var displayName: String {
        switch self {
        case .confirmedPhishing: return "Confirmed Phishing"
        case .safe: return "Safe"
        case .needsInfo: return "Needs Info"
        }
    }

    var icon: String {
        switch self {
        case .confirmedPhishing: return "exclamationmark.octagon.fill"
        case .safe: return "checkmark.shield.fill"
        case .needsInfo: return "questionmark.circle.fill"
        }
    }
}

/// Pure suggestion policy — unit-tested; the admin always decides.
enum TriageVerdictPolicy {
    /// (suggested verdict, one-line reason)
    static func suggestion(phishingRisk: String?, iocCount: Int,
                           hasAttachments: Bool) -> (verdict: TriageVerdict, reason: String) {
        let risk = phishingRisk?.lowercased()
        if risk == "high" {
            return (.confirmedPhishing, "High phishing risk" + (iocCount > 0 ? " + \(iocCount) indicator\(iocCount == 1 ? "" : "s")" : ""))
        }
        if risk == "medium" || iocCount >= 3 {
            let why = risk == "medium" ? "Medium phishing risk" : "\(iocCount) suspicious indicators"
            return (.needsInfo, "\(why) — verify with the reporter before deciding")
        }
        if iocCount > 0 || hasAttachments {
            return (.needsInfo, iocCount > 0 ? "\(iocCount) indicator\(iocCount == 1 ? "" : "s") worth a look" : "Carries an attachment — open with care")
        }
        return (.safe, "No phishing signals or indicators detected")
    }
}

/// Intake + verdict actions. All storage goes through the existing
/// authorities (store, FTS, review tags, audit chain) — nothing new.
@MainActor
final class TriageQueueService: ObservableObject {
    static let shared = TriageQueueService()

    @Published private(set) var lastIntakeNote: String? = nil

    private var observer: NSObjectProtocol?

    /// The SQL query for the pending queue.
    static var pendingQuery: EmailQuery {
        var q = EmailQuery.all
        q.userTag = TriageVerdict.pendingTag
        return q
    }

    private init() {}

    /// Start receiving watch-folder imports. Idempotent.
    func activate() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .newEmailsImported, object: nil, queue: .main
        ) { [weak self] notification in
            guard let emails = notification.userInfo?["emails"] as? [MBOXParser.RawEmail] else { return }
            let fileName = notification.userInfo?["fileName"] as? String ?? "watched folder"
            Task { @MainActor in
                await self?.intake(emails, from: fileName)
            }
        }
    }

    /// Persist + index + stamp pending + audit-log. Message-ID dedup means a
    /// re-forwarded email doesn't duplicate; already-stored emails still get
    /// queued (the tag applies by id either way).
    func intake(_ emails: [MBOXParser.RawEmail], from fileName: String) async {
        guard !emails.isEmpty else { return }
        do {
            try await SQLiteEmailStore.shared.insertBatch(emails)
            try? await FTSSearchIndex.shared.indexBatch(emails)
            _ = try? await ArchiveCorpusRevision.shared.bump()
        } catch {
            lastIntakeNote = "Intake failed for \(fileName): \(error.localizedDescription)"
            return
        }
        ReviewStateService.shared.addTag(TriageVerdict.pendingTag, to: emails.map(\.id))
        ForensicManager.shared.logAction(
            "Triage intake", detail: "\(emails.count) email(s) from \(fileName) queued as \(TriageVerdict.pendingTag)")
        lastIntakeNote = "\(emails.count) email(s) from \(fileName) added to the triage queue."
        NotificationCenter.default.post(name: .parsingFinished, object: nil)
    }

    /// Issue a verdict: swap pending → verdict tag, post a VRD document,
    /// audit-log both. The VRD number is what an incident ticket cites.
    func issueVerdict(_ verdict: TriageVerdict, for email: MBOXParser.RawEmail) {
        ReviewStateService.shared.removeTag(TriageVerdict.pendingTag, from: [email.id])
        ReviewStateService.shared.addTag(verdict.rawValue, to: [email.id])
        let subject = email.headers["Subject"] ?? "(No Subject)"
        Task { @MainActor in
            let number = await DocumentRegistry.post(
                .triageVerdict,
                summary: "\(verdict.displayName): \(subject)",
                refs: email.id.uuidString)
            ForensicManager.shared.logAction(
                "Triage verdict: \(verdict.displayName)",
                detail: "\(number.map { "\($0) — " } ?? "")\(subject) — \(email.id.uuidString)")
        }
    }
}
