//
//  ManagedLiveMailPolicy.swift
//  ENT4-02 (owner 2026-11-24): an organisation controls Live Mail through its
//  MDM. Every key is optional; without one Live Mail behaves exactly as in the
//  public 4.0 app. A managed value is a HARD gate — the person cannot change it
//  in the app, and Settings says "Set by your organisation".
//
//  Keys (managed app configuration, documented in the IT admin guide):
//    allowConnectedMail     bool      — false: the Live Mail page and every mail
//                                       connection are off (default true)
//    allowedMailProviders   [string]  — gmail, microsoft365 (or outlook), icloud,
//                                       fastmail, imap (any other server); absent = all
//    allowSendMail          bool      — false: nothing is sent (default true)
//    allowServerChanges     bool      — false: nothing is changed or deleted on
//                                       the mail server (default true)
//    syncOnlyOnWiFi         bool      — locks automatic sync's "Only on Wi-Fi"
//    syncOnlyWhileCharging  bool      — locks automatic sync's "Only while charging"
//    maxDownloadMBps        number    — highest average download speed in MB/s;
//                                       the person may choose a lower one
//
//  Enforced where the network is granted (ConnectedMailRuntime.reloadAccounts
//  builds each account's network modes through `networkModes`), at every entry
//  point (add account, switch a mode on, queue a message, change server mail)
//  and in the interface.
//

import Foundation
import MailConnectivity

/// The provider families an organisation can allow.
enum ManagedMailProvider: String, CaseIterable, Sendable {
    case gmail, microsoft365, icloud, fastmail, imap

    /// The value an admin wrote, with the obvious other names accepted.
    init?(managedName: String) {
        switch managedName.trimmingCharacters(in: .whitespaces).lowercased() {
        case "gmail", "google": self = .gmail
        case "microsoft365", "microsoft 365", "m365", "office365", "outlook", "microsoft", "graph": self = .microsoft365
        case "icloud": self = .icloud
        case "fastmail": self = .fastmail
        case "imap", "otherimap", "other": self = .imap
        default: return nil
        }
    }

    init(_ choice: MailProviderChoice) {
        switch choice {
        case .gmail, .gmailAppPassword: self = .gmail
        case .outlook: self = .microsoft365
        case .iCloud: self = .icloud
        case .fastmail: self = .fastmail
        case .otherIMAP: self = .imap
        }
    }

    /// The family of an account already added (an IMAP account by its server).
    init(_ account: MailAccount) {
        switch account.provider {
        case .gmail: self = .gmail
        case .microsoftGraph: self = .microsoft365
        case .imap:
            let host = (account.host ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if ConnectedMailErrorText.isGmailHost(host) { self = .gmail }
            else if host == IMAPProviderPreset.iCloud.host { self = .icloud }
            else if host == IMAPProviderPreset.fastmail.host { self = .fastmail }
            else if host == "outlook.office365.com" { self = .microsoft365 }
            else { self = .imap }
        }
    }
}

struct ManagedLiveMailPolicy: Equatable, Sendable {
    var allowConnectedMail = true
    /// nil = every provider.
    var allowedProviders: Set<ManagedMailProvider>?
    var allowSendMail = true
    var allowServerChanges = true
    /// nil = the person decides.
    var syncOnlyOnWiFi: Bool?
    var syncOnlyWhileCharging: Bool?
    /// Bytes per second; nil = no organisation limit.
    var maxDownloadBytesPerSecond: Int64?

    init() {}

    /// Read from a managed dictionary. A value of the wrong type is ignored
    /// (and reported by `ManagedConfig.validationIssues`).
    init(config: [String: Any]) {
        if let v = config["allowConnectedMail"] as? Bool { allowConnectedMail = v }
        if let names = config["allowedMailProviders"] as? [String] {
            allowedProviders = Set(names.compactMap(ManagedMailProvider.init(managedName:)))
        }
        if let v = config["allowSendMail"] as? Bool { allowSendMail = v }
        if let v = config["allowServerChanges"] as? Bool { allowServerChanges = v }
        syncOnlyOnWiFi = config["syncOnlyOnWiFi"] as? Bool
        syncOnlyWhileCharging = config["syncOnlyWhileCharging"] as? Bool
        if let mb = Self.number(config["maxDownloadMBps"]), mb > 0 {
            maxDownloadBytesPerSecond = max(1, Int64((mb * 1_000_000).rounded()))
        }
    }

    /// The policy in force on this device.
    static var current: ManagedLiveMailPolicy { ManagedLiveMailPolicy(config: ManagedConfig.configuration) }

    /// True when the organisation set any Live Mail key.
    var isManaged: Bool { self != ManagedLiveMailPolicy() }

    /// A number from a property list (never a Bool, which bridges to NSNumber too).
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    // MARK: Questions the app asks

    func allows(_ provider: ManagedMailProvider) -> Bool { allowedProviders?.contains(provider) ?? true }
    func allows(_ choice: MailProviderChoice) -> Bool { allows(ManagedMailProvider(choice)) }
    func allows(_ account: MailAccount) -> Bool { allows(ManagedMailProvider(account)) }

    func allows(_ mode: MailAccount.Mode) -> Bool {
        switch mode {
        case .capture: return true
        case .send: return allowSendMail
        case .serverActions: return allowServerChanges
        }
    }

    /// The network modes an account is granted: the organisation's refusals removed.
    func networkModes(_ modes: Set<MailAccountMode>) -> Set<MailAccountMode> {
        var out = modes
        if !allowSendMail { out.remove(.sendMail) }
        if !allowServerChanges { out.remove(.changeServerMail) }
        return out
    }

    /// The automatic-sync settings with the organisation's locks applied.
    func applied(to schedule: ConnectedSyncSchedule) -> ConnectedSyncSchedule {
        var out = schedule
        if let wifi = syncOnlyOnWiFi { out.wifiOnly = wifi }
        if let charging = syncOnlyWhileCharging { out.whileChargingOnly = charging }
        return out
    }

    /// The download speed limit in force: the lower of the person's and the organisation's (0 = none).
    func speedLimit(personal: Int64) -> Int64 {
        guard let org = maxDownloadBytesPerSecond else { return personal }
        return personal > 0 ? min(personal, org) : org
    }

    // MARK: Sentences

    static var setByOrganisation: String { String(localized: "Set by your organisation") }

    static var providerRefused: String {
        String(localized: "Your organisation does not allow this kind of mail account on this device. Mail already saved stays in the archive.")
    }

    static func modeRefused(_ mode: MailAccount.Mode) -> String? {
        switch mode {
        case .capture: return nil
        case .send: return String(localized: "Your organisation does not allow sending mail from mailin on this device.")
        case .serverActions: return String(localized: "Your organisation does not allow changing mail on the server from mailin on this device.")
        }
    }

    /// Why the organisation refuses `mode` for `account`, or nil.
    func refusal(_ mode: MailAccount.Mode, account: MailAccount) -> String? {
        if !allows(account) { return Self.providerRefused }
        return allows(mode) ? nil : Self.modeRefused(mode)
    }
}

extension ManagedConfig {
    /// Posted (main queue) when the managed dictionary changes, after the
    /// module registry has applied it.
    static let didChange = Notification.Name("mailin.managedConfig.didChange")
}
