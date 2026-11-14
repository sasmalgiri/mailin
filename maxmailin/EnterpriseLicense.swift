//
//  EnterpriseLicense.swift
//  maxmailin
//
//  Enterprise edition licensing (LICENSING.md). The enterprise build is a
//  Custom App distributed through Apple Business Manager; it has no in-app
//  purchases. An organization's license is a signed key, checked here
//  offline against the embedded public key (no network — rule 7):
//
//    MAILIN1.<base64url payload JSON>.<base64url Ed25519 signature>
//
//  The key comes from the MDM profile (`licenseKey`, see EnterpriseConfig)
//  or is pasted in Settings ▸ About. Keys are issued with
//  Scripts/mailin-license.swift.
//
//  What a license decides — and what it never does:
//   • Valid (or within 30 days after expiry, with a warning): Professional.
//   • No key, an invalid key, or expired beyond the grace period: Personal —
//     the whole archive stays readable, searchable and exportable; only the
//     Professional tools wait for a license. Nothing is ever locked away or
//     deleted (rule 1).
//   • Seats are stated, not enforced: the app cannot count installs offline.
//

import Foundation
import CryptoKit

struct EnterpriseLicense: Equatable {
    struct Payload: Codable, Equatable {
        var v: Int
        var org: String
        var seats: Int
        var issued: String
        var expires: String?
        var id: String
    }

    enum Status: Equatable {
        case missing
        case invalid(String)
        case valid(Payload)
        /// Past expiry but inside the grace period; `daysLeft` until Personal.
        case grace(Payload, daysLeft: Int)
        case expired(Payload)
    }

    /// The public half of the key pair in ~/mailin-license-keys (created
    /// 2026-10-11 with `mailin-license.swift keygen`).
    static let publicKeyBase64 = "JL/12LgMbp308a6k0o3y+DjIvUQ0XIW1ZupKizhXYzg="
    static let graceDays = 30
    static let enteredKeyDefaultsKey = "enterprise.licenseKey"
    private static let highWaterKey = "enterprise.licenseClockHighWater"

    let status: Status

    /// Professional while licensed (or in grace); Personal otherwise.
    var tier: PurchaseTier {
        switch status {
        case .valid, .grace: return .professional
        case .missing, .invalid, .expired: return .personal
        }
    }

    /// Checks `key` against `publicKey` at `now`. Pure, for tests.
    static func evaluate(key: String?, now: Date, publicKey: String = publicKeyBase64) -> EnterpriseLicense {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return EnterpriseLicense(status: .missing)
        }
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == "MAILIN1",
              let json = unb64url(parts[1]), let signature = unb64url(parts[2]) else {
            return EnterpriseLicense(status: .invalid(String(localized: "This is not a mailin license key.")))
        }
        guard let pub = Data(base64Encoded: publicKey),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
              verifier.isValidSignature(signature, for: json) else {
            return EnterpriseLicense(status: .invalid(String(localized: "The license key's signature does not match — it was changed or not issued for mailin.")))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json), payload.v == 1 else {
            return EnterpriseLicense(status: .invalid(String(localized: "This license key is from a newer version of mailin.")))
        }
        guard let expiresText = payload.expires else { return EnterpriseLicense(status: .valid(payload)) }
        guard let expires = day(expiresText) else {
            return EnterpriseLicense(status: .invalid(String(localized: "The license key's expiry date cannot be read.")))
        }
        let end = expires.addingTimeInterval(86_400)   // valid through the whole expiry day (UTC)
        if now < end { return EnterpriseLicense(status: .valid(payload)) }
        let graceEnd = end.addingTimeInterval(Double(graceDays) * 86_400)
        if now < graceEnd {
            let left = Int((graceEnd.timeIntervalSince(now) / 86_400).rounded(.up))
            return EnterpriseLicense(status: .grace(payload, daysLeft: left))
        }
        return EnterpriseLicense(status: .expired(payload))
    }

    /// The license in force on this device: MDM key first, then a pasted key.
    /// The clock is never allowed to run backwards past the latest date seen,
    /// so setting the date back does not revive an expired key.
    static func current(defaults: UserDefaults = .standard, managedKey: String? = ManagedConfig.licenseKey) -> EnterpriseLicense {
        let seen = defaults.double(forKey: highWaterKey)
        let now = max(Date(), Date(timeIntervalSince1970: seen))
        if now.timeIntervalSince1970 > seen { defaults.set(now.timeIntervalSince1970, forKey: highWaterKey) }
        let key = managedKey ?? defaults.string(forKey: enteredKeyDefaultsKey)
        return evaluate(key: key, now: now)
    }

    /// One line for About and the banner.
    var summary: String {
        switch status {
        case .missing:
            return String(localized: "No license key. The archive, search and exports work; Professional tools need your organization's license key.")
        case .invalid(let why):
            return why
        case .valid(let p):
            let until = p.expires.map { String(localized: "until \($0)") } ?? String(localized: "with no expiry")
            return String(localized: "Licensed to \(p.org) — \(p.seats) seats, \(until).")
        case .grace(let p, let left):
            return String(localized: "The license for \(p.org) expired on \(p.expires ?? ""). Professional tools keep working for \(left) more days — renew to continue.")
        case .expired(let p):
            return String(localized: "The license for \(p.org) expired on \(p.expires ?? ""). The archive, search and exports work; renew to use the Professional tools again.")
        }
    }

    private static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    private static func unb64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
