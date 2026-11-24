//
//  EnterpriseChannel.swift
//  ENT4-03 (owner 2026-11-24): the enterprise edition reaches organisations two ways.
//
//   • App Store listing (channel A, the 4.0 default): "mailin Enterprise" is a
//     paid app that organisations buy in volume through Apple Business Manager.
//     The purchase IS the licence — every feature is available without a key
//     (App Review rejects a paid app that needs an outside key to work). A key
//     pushed by MDM, if any, only names the organisation and its seats in About
//     and in Managed App Feedback.
//   • Custom App (channel C, per customer, later): a private listing with the
//     organisation's own terms. The 3.0 rule stays: a valid signed key (or the
//     30-day grace) = everything; without one never below Personal; nothing is
//     ever locked away.
//
//  One build decides by a build setting, never at run time: the Custom App
//  build adds `ENTERPRISE_CUSTOM_APP` (Scripts/testflight.sh --channel custom).
//

import Foundation

enum EnterpriseChannel: String, Sendable {
    case appStoreListing = "appStore"
    case customApp = "customApp"

    /// The channel this build was made for.
    static var current: EnterpriseChannel {
        #if ENTERPRISE_CUSTOM_APP
        return .customApp
        #else
        return .appStoreListing
        #endif
    }

    /// The tier the enterprise edition runs at with `license` in force.
    func tier(for license: EnterpriseLicense) -> PurchaseTier {
        switch self {
        case .appStoreListing: return .professional
        case .customApp: return license.tier
        }
    }

    /// True when a key is needed for the Professional tools.
    var needsLicenseKey: Bool { self == .customApp }

    /// The line About shows for the licence.
    func summary(for license: EnterpriseLicense) -> String {
        guard self == .appStoreListing else { return license.summary }
        switch license.status {
        case .missing:
            return String(localized: "Every feature is included in your organisation's purchase. No license key is needed.")
        case .valid:
            return license.summary
        case .invalid(let why):
            return String(localized: "\(why) Every feature stays available; the key only names your organisation.")
        case .grace(let p, _), .expired(let p):
            return String(localized: "The organisation key for \(p.org) expired on \(p.expires ?? ""). Every feature stays available; the key only names your organisation.")
        }
    }
}
