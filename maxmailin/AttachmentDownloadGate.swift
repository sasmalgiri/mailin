//
//  AttachmentDownloadGate.swift
//  maxmailin
//
//  IPAD-04 (gate 1 walk, 2026-11-08): the per-attachment Download button in
//  the message view was disabled on a stored message with no reason — it
//  needed a live parse-time temp file (`fileURL`), which a stored message
//  never has — although the plan table says Free includes a daily allowance
//  of attachment saves. The button now follows the access policy (LIFE-06,
//  `AccessPolicy.attachmentDownloadLimit`): enabled within the allowance,
//  unlimited once a plan was held, and when the allowance is used it says
//  so with the upgrade path. The bytes come from the stored message
//  (`EvidenceAttachmentOpener.temporaryFile`), as Open does.
//

import Foundation

struct AttachmentDownloadDecision: Equatable, Sendable {
    /// The button can be pressed.
    let isEnabled: Bool
    /// Saves left today on the Free plan; nil = no daily limit.
    let remainingToday: Int?
    /// One line shown with the button (the allowance, or why it is off); nil = nothing to say.
    let note: String?
    /// The upgrade action is offered next to the note.
    let offersUpgrade: Bool
}

enum AttachmentDownloadGate {
    /// The counter the list's "save all attachments" already uses, reset each
    /// day by `StoreManager.resetDailyCountersIfNeeded`.
    static let usedTodayKey = "freeAttachmentDownloadCount"

    static func decide(policy: AccessPolicy, usedToday: Int,
                       allowance: Int = StoreManager.freeAttachmentDownloadsPerDay) -> AttachmentDownloadDecision {
        guard let remaining = policy.attachmentDownloadLimit(usedToday: usedToday, freeAllowance: allowance) else {
            return AttachmentDownloadDecision(isEnabled: true, remainingToday: nil, note: nil, offersUpgrade: false)
        }
        if remaining > 0 {
            return AttachmentDownloadDecision(isEnabled: true, remainingToday: remaining,
                                              note: String(localized: "Free plan: \(remaining) of \(allowance) attachment saves left today."),
                                              offersUpgrade: false)
        }
        return AttachmentDownloadDecision(isEnabled: false, remainingToday: 0,
                                          note: String(localized: "Free plan: today's \(allowance) attachment saves are used. Personal and Professional have no daily limit."),
                                          offersUpgrade: true)
    }

    /// Counts one save against today's Free allowance (no-op once a plan was held).
    static func recordSave(policy: AccessPolicy, defaults: UserDefaults = .standard) {
        guard policy.attachmentDownloadLimit(usedToday: 0, freeAllowance: 1) != nil else { return }
        defaults.set(defaults.integer(forKey: usedTodayKey) + 1, forKey: usedTodayKey)
    }
}
