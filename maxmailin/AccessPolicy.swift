//
//  AccessPolicy.swift
//  maxmailin
//
//  LIFE-06 — the data-access policy the owner adopted on 6 November 2026
//  (FIVE_JOBS_MASTER_PLAN.md §12.2): a customer keeps reading, searching,
//  opening attachments and exporting (as .eml / mbox) what they already
//  imported after a subscription ends or is refunded; new paid work — new
//  imports beyond the Free rules, OCR, AI, specialist productions — follows
//  the plan in force. Imported mail is never deleted because an entitlement
//  changed. Maintenance (relink, rebuild, backup, restore) is never gated.
//
//  One table, consulted by the data layer (`StoreManager.publishAccessScope`),
//  the export runner and the views, so the policy cannot drift between them.
//

@testable import ArchiveCore
import Foundation

/// What the store has proved, plus what it proved before.
enum EntitlementState: Equatable, Sendable {
    /// Never had a paid plan.
    case free
    /// A verified paid subscription.
    case active(PurchaseTier)
    /// A verified lifetime purchase: never expires.
    case lifetime(PurchaseTier)
    /// A paid plan was held and is no longer active: expired, cancelled,
    /// refunded or revoked. The data stays the customer's.
    case lapsed(previous: PurchaseTier)
}

struct AccessPolicy: Equatable, Sendable {
    let state: EntitlementState

    /// New paid work (imports beyond the Free rules, OCR, AI, specialist tools).
    var allowsPaidWork: Bool {
        switch state {
        case .active, .lifetime: return true
        case .free, .lapsed: return false
        }
    }

    /// True after a plan ended: the archive stays open; only new paid work stops.
    var isLapsed: Bool { if case .lapsed = state { return true } else { return false } }

    /// Whole archive for everyone who ever paid; the newest 500 for Free.
    var archiveReadLimit: Int? {
        switch state {
        case .free: return StoreManager.freeEmailLimit
        case .active, .lifetime, .lapsed: return nil
        }
    }
    var readsWholeArchive: Bool { archiveReadLimit == nil }

    /// Export cap per run. Mail-preserving .eml / mbox of already-imported
    /// mail is never capped once a plan was held (basic portability); reports
    /// and the other formats follow the Free rules when no plan is active.
    func exportCap(for format: UnifiedExportFormat) -> Int? {
        switch state {
        case .active, .lifetime: return nil
        case .lapsed: return (format == .emlFiles || format == .mbox) ? nil : StoreManager.freeEmailLimit
        case .free: return StoreManager.freeEmailLimit
        }
    }

    /// Daily attachment saves: unlimited once a plan was held (opening your
    /// own attachments is reading), Free keeps its daily allowance.
    func attachmentDownloadLimit(usedToday: Int, freeAllowance: Int) -> Int? {
        switch state {
        case .active, .lifetime, .lapsed: return nil
        case .free: return max(0, freeAllowance - usedToday)
        }
    }

    /// Relink, rebuild the index, back up, restore, read from retained text — always.
    var allowsMaintenance: Bool { true }

    /// Said on the purchase screen and in help, in every state.
    static var afterExpiryStatement: String {
        String(localized: "When a subscription ends, everything you imported stays yours: you can still browse, read, search it and export it as .eml or mbox files. New imports beyond the Free rules, OCR, AI and professional tools need an active plan. Nothing is ever deleted because a plan changed.")
    }

    /// The one-line ownership text for a lapsed plan.
    static func lapsedOwnershipText(previous: PurchaseTier) -> String {
        String(localized: "Your \(previous.displayName) plan has ended. Your archive stays readable, searchable and exportable as .eml or mbox; new imports, OCR, AI and professional tools need an active plan again.")
    }
}
