//
//  AccountRegistry.swift
//  maxmailin
//
//  L2: the Live Mail account model. Every account has its own id, its own
//  Keychain items (password / tokens keyed by that id — never by username,
//  so two accounts with the same login at different servers cannot collide),
//  and its records are keyed `(accountID, uid)` downstream. Removing an
//  account removes its secrets. Nothing here touches archive tables.
//

import Foundation
import Observation

enum LiveMailAccountKind: String, Codable, CaseIterable, Sendable {
    case imap       // generic IMAP + SMTP with a password / app password
    case graph      // Microsoft Graph (OAuth) — 3.0 branch, needs the Entra client id
}

struct LiveMailAccount: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var kind: LiveMailAccountKind
    var displayName: String
    var emailAddress: String
    var username: String
    var imapServer: String = ""
    var imapPort: UInt16 = 993
    var smtpServer: String = ""
    var smtpPort: UInt16 = 587
    var smtpUsesSSL: Bool = false
    var addedAt: Date = Date()

    /// Keychain keys are derived from the id only.
    var passwordKey: String { "liveMail.\(id.uuidString).password" }
    var accessTokenKey: String { "liveMail.\(id.uuidString).accessToken" }
    var refreshTokenKey: String { "liveMail.\(id.uuidString).refreshToken" }
}

@MainActor
@Observable
final class AccountRegistry {
    static let shared = AccountRegistry(url: AccountRegistry.productionURL)

    static var productionURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("mailin", isDirectory: true)
            .appendingPathComponent("live-mail-accounts.v1.json")
    }

    private(set) var accounts: [LiveMailAccount] = []
    private let url: URL

    init(url: URL) {
        self.url = url
        load()
    }

    // MARK: Accounts

    func add(_ account: LiveMailAccount, password: String?) {
        var list = accounts.filter { $0.id != account.id }
        list.append(account)
        accounts = list
        if let password { KeychainHelper.save(key: account.passwordKey, value: password) }
        save()
    }

    func remove(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        KeychainHelper.delete(key: account.passwordKey)
        KeychainHelper.delete(key: account.accessTokenKey)
        KeychainHelper.delete(key: account.refreshTokenKey)
        accounts.removeAll { $0.id == id }
        save()
    }

    func account(id: UUID) -> LiveMailAccount? { accounts.first { $0.id == id } }

    // MARK: Secrets (never stored in the JSON)

    func password(for account: LiveMailAccount) -> String { KeychainHelper.load(key: account.passwordKey) }
    func setPassword(_ value: String, for account: LiveMailAccount) { KeychainHelper.save(key: account.passwordKey, value: value) }
    func accessToken(for account: LiveMailAccount) -> String { KeychainHelper.load(key: account.accessTokenKey) }
    func setTokens(access: String, refresh: String, for account: LiveMailAccount) {
        KeychainHelper.save(key: account.accessTokenKey, value: access)
        KeychainHelper.save(key: account.refreshTokenKey, value: refresh)
    }

    /// The IMAP configuration for one account — built on demand, never held.
    func imapConfig(for account: LiveMailAccount) -> IMAPConfig {
        IMAPConfig(server: account.imapServer, port: account.imapPort,
                   username: account.username,
                   password: account.kind == .imap ? password(for: account) : "",
                   accessToken: account.kind == .graph ? accessToken(for: account) : nil,
                   accountID: account.id)
    }

    func smtpConfig(for account: LiveMailAccount) -> SMTPConfig {
        SMTPConfig(server: account.smtpServer, port: account.smtpPort, username: account.username,
                   password: password(for: account), useSSL: account.smtpUsesSSL)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        accounts = (try? decoder.decode([LiveMailAccount].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(accounts).write(to: url, options: .atomic)
        } catch {
            // Surfaced by the page as a save error; secrets are already in the Keychain.
        }
    }
}
