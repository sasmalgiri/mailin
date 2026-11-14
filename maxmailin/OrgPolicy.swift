@testable import ArchiveCore
//
//  OrgPolicy.swift
//  maxmailin
//
//  Enterprise authorisation (ENTERPRISE_TODO.md A-1 – A-4, B-2). An
//  organisation pushes the person's ROLE and its data-loss rules through the
//  MDM (managed app configuration, see EnterpriseConfig.swift). Every
//  restricted action asks this one place, which answers with nil (allowed) or
//  the sentence to show (why not).
//
//  Unmanaged installs — private users — are Administrator with exports and
//  printing allowed: exactly the behaviour before roles existed.
//
//  An unrecognised role value fails CLOSED (Viewer) and is reported as a
//  configuration error: a typo must never grant more than the admin meant.
//

import Foundation
#if os(macOS)
import AppKit
#endif

/// Ordered: each role can do everything the one before it can.
enum OrgRole: String, CaseIterable, Comparable, Sendable {
    case viewer, reviewer, examiner, administrator

    static func < (a: OrgRole, b: OrgRole) -> Bool { a.rank < b.rank }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var displayName: String {
        switch self {
        case .viewer: return String(localized: "Viewer")
        case .reviewer: return String(localized: "Reviewer")
        case .examiner: return String(localized: "Examiner")
        case .administrator: return String(localized: "Administrator")
        }
    }

    /// What the role is for, in one line (About ▸ Your role).
    var summary: String {
        switch self {
        case .viewer: return String(localized: "Read and search the archive.")
        case .reviewer: return String(localized: "Read, search, tag, code and annotate.")
        case .examiner: return String(localized: "Review, import, export, print, place legal holds and produce.")
        case .administrator: return String(localized: "Everything, including permanent deletion, releasing holds, modules, restore and the license.")
        }
    }
}

enum OrgPermission: String, CaseIterable, Sendable {
    case review           // tags, coding, notes, pins, review batches, trash (reversible)
    case importMail
    case export
    case print
    case placeHold
    case produce          // Bates numbering, productions
    case deleteEmails     // permanent deletion
    case releaseHold
    case manageModules
    case restoreSnapshot
    case manageLicense
    case relocateArchive

    var minimumRole: OrgRole {
        switch self {
        case .review: return .reviewer
        case .importMail, .export, .print, .placeHold, .produce: return .examiner
        case .deleteEmails, .releaseHold, .manageModules, .restoreSnapshot, .manageLicense, .relocateArchive:
            return .administrator
        }
    }

    var displayName: String {
        switch self {
        case .review: return String(localized: "tag, code and annotate")
        case .importMail: return String(localized: "import mail")
        case .export: return String(localized: "export or share")
        case .print: return String(localized: "print")
        case .placeHold: return String(localized: "place legal holds")
        case .produce: return String(localized: "number and produce documents")
        case .deleteEmails: return String(localized: "delete emails permanently")
        case .releaseHold: return String(localized: "release legal holds")
        case .manageModules: return String(localized: "change modules")
        case .restoreSnapshot: return String(localized: "restore a snapshot")
        case .manageLicense: return String(localized: "change the license")
        case .relocateArchive: return String(localized: "move the archive")
        }
    }
}

enum OrgPolicy {
    /// The decision, from explicit inputs (pure — for tests and for the
    /// store gate, which runs off the main actor).
    static func denial(_ permission: OrgPermission, role: OrgRole,
                       allowExport: Bool = true, allowPrint: Bool = true,
                       org: String? = nil) -> String? {
        if permission == .export && !allowExport {
            return org.map { String(localized: "\($0) has turned off exporting and sharing from mailin on this device.") }
                ?? String(localized: "Your organization has turned off exporting and sharing from mailin on this device.")
        }
        if permission == .print && !allowPrint {
            return org.map { String(localized: "\($0) has turned off printing from mailin on this device.") }
                ?? String(localized: "Your organization has turned off printing from mailin on this device.")
        }
        guard role < permission.minimumRole else { return nil }
        return String(localized: "Your role is \(role.displayName). To \(permission.displayName), the \(permission.minimumRole.displayName) role or higher is needed.")
    }

    /// The person's role on this device. Unmanaged, or managed without a
    /// `role` key: Administrator. An unrecognised value: Viewer (fail closed).
    static var role: OrgRole {
        guard let raw = ManagedConfig.roleValue else { return .administrator }
        return OrgRole(rawValue: raw.lowercased()) ?? .viewer
    }

    static func denial(_ permission: OrgPermission) -> String? {
        denial(permission, role: role,
               allowExport: ManagedConfig.allowExport, allowPrint: ManagedConfig.allowPrint,
               org: ManagedConfig.orgName)
    }

    static func allows(_ permission: OrgPermission) -> Bool { denial(permission) == nil }

    /// For funnels that have no screen of their own to say why: shows the
    /// reason (macOS alert) and returns false when the action is not allowed.
    @MainActor
    @discardableResult
    static func confirmAllowed(_ permission: OrgPermission) -> Bool {
        guard let why = denial(permission) else { return true }
        ForensicManager.shared.logAction("Action refused by organization policy", detail: "\(permission.rawValue): \(why)")
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = String(localized: "Not available with your role")
        alert.informativeText = why
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
        #endif
        return false
    }

    /// Pushes the store-level gate (permanent delete and legal holds are
    /// refused in the archive itself, whichever screen or engine asks).
    static func installStoreGate() {
        StorePolicyGate.check = { action in
            let permission: OrgPermission
            switch action {
            case .deleteEmails: permission = .deleteEmails
            case .placeHold: permission = .placeHold
            case .releaseHold: permission = .releaseHold
            }
            return OrgPolicy.denial(permission)
        }
    }
}

#if os(macOS)
/// A save panel that honours the organisation's export policy and role: when
/// exporting is not allowed it says why and behaves as a cancelled panel, so
/// every caller's existing "cancelled" path applies.
final class ManagedSavePanel: NSSavePanel {
    override func runModal() -> NSApplication.ModalResponse {
        guard OrgPolicy.confirmAllowed(.export) else { return .cancel }
        return super.runModal()
    }

    override func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        guard OrgPolicy.confirmAllowed(.export) else { handler(.cancel); return }
        super.begin(completionHandler: handler)
    }

    override func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        guard OrgPolicy.confirmAllowed(.export) else { handler(.cancel); return }
        super.beginSheetModal(for: window, completionHandler: handler)
    }
}
#endif
