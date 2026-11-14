//
//  TestDoubles.swift
//  MailConnectivityTests
//
//  In-memory credential store, fake Keychain and fake token endpoint.
//

import Foundation
import Security
@testable import MailConnectivity
import ArchiveCore

/// Account-scoped secrets in memory, with write-failure injection.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failWrites: OSStatus?
    private var failReads: OSStatus?
    private(set) var writeCount = 0

    private func key(_ kind: CredentialKind, _ account: UUID) -> String { KeychainCredentialStore.itemAccount(account, kind) }

    func setWriteFailure(_ status: OSStatus?) { lock.lock(); failWrites = status; lock.unlock() }
    func setReadFailure(_ status: OSStatus?) { lock.lock(); failReads = status; lock.unlock() }
    var allSecrets: [Data] { lock.lock(); defer { lock.unlock() }; return Array(items.values) }

    func read(_ kind: CredentialKind, account: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let failReads { throw CredentialStoreError.keychain(operation: "read", status: failReads) }
        return items[key(kind, account)]
    }

    func write(_ secret: Data, kind: CredentialKind, account: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if let failWrites { throw CredentialStoreError.keychain(operation: "saved", status: failWrites) }
        items[key(kind, account)] = secret
        writeCount += 1
    }

    func delete(_ kind: CredentialKind, account: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(kind, account)] = nil
    }
}

/// A Keychain whose statuses the test chooses; records every call.
final class FakeKeychain: KeychainAPI, @unchecked Sendable {
    private let lock = NSLock()
    var stored: [String: Data] = [:]
    var updateStatus: OSStatus? = nil      // nil = behave normally
    var addStatus: OSStatus? = nil
    private(set) var calls: [String] = []

    private func account(_ q: [String: Any]) -> String { (q[kSecAttrService as String] as? String ?? "") + "|" + (q[kSecAttrAccount as String] as? String ?? "") }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        calls.append("copy")
        guard let data = stored[account(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append("add")
        if let addStatus { let s = addStatus; self.addStatus = nil; return s }
        if stored[account(attributes)] != nil { return errSecDuplicateItem }
        stored[account(attributes)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append("update")
        if let updateStatus { return updateStatus }
        guard stored[account(query)] != nil else { return errSecItemNotFound }
        stored[account(query)] = changes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append("delete")
        // Like SecItemDelete: a query without an account matches every item of the service.
        if query[kSecAttrAccount as String] == nil {
            let prefix = (query[kSecAttrService as String] as? String ?? "") + "|"
            let matching = stored.keys.filter { $0.hasPrefix(prefix) }
            matching.forEach { stored[$0] = nil }
            return matching.isEmpty ? errSecItemNotFound : errSecSuccess
        }
        return stored.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}

/// The token endpoint: answers per refresh token, records every request,
/// optionally holds requests until released.
actor FakeTokenEndpoint: TokenTransport {
    struct Request: Sendable { let url: URL; let form: [String: String]; let raw: String }
    private(set) var requests: [Request] = []
    var responses: [String: (Int, String)] = [:]      // keyed by refresh_token or code
    var delayNanoseconds: UInt64 = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    func respond(to key: String, status: Int = 200, json: String) { responses[key] = (status, json) }
    func setDelay(_ ns: UInt64) { delayNanoseconds = ns }
    func hold() { holding = true }
    func release() { holding = false; gate?.resume(); gate = nil }
    var requestCount: Int { requests.count }

    nonisolated static func decodeForm(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    func postForm(_ url: URL, body: Data) async throws -> (status: Int, body: Data) {
        let form = Self.decodeForm(body)
        requests.append(Request(url: url, form: form, raw: String(decoding: body, as: UTF8.self)))
        if holding { await withCheckedContinuation { gate = $0 } }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let key = form["refresh_token"] ?? form["code"] ?? ""
        let (status, json) = responses[key] ?? (400, #"{"error":"invalid_request"}"#)
        return (status, Data(json.utf8))
    }
}

/// Account records in memory, with save-failure injection (disk full).
actor FakeRecordStore: ConnectedAccountRecordStore {
    private var records: [UUID: ConnectedAccountRecord] = [:]
    var failSaves: String?
    func setFailure(_ why: String?) { failSaves = why }
    struct DiskFull: LocalizedError { let why: String; var errorDescription: String? { why } }
    func saveAccount(_ record: ConnectedAccountRecord) async throws {
        if let failSaves { throw DiskFull(why: failSaves) }
        records[record.accountID] = record
    }
    func accountRecords() async throws -> [ConnectedAccountRecord] { records.values.sorted { $0.createdAt < $1.createdAt } }
}

struct FakeLegacyKeychain: LegacyKeychainReading {
    let box: Box
    final class Box: @unchecked Sendable { var items: [String: Data]; init(_ i: [String: Data]) { items = i } }
    func read(key: String) throws -> Data? { box.items[key] }
    func delete(key: String) throws { box.items[key] = nil }
}

enum Fixtures {
    static let google = OAuthClientConfiguration(
        issuer: "https://accounts.google.com",
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        clientID: "123-test.apps.googleusercontent.com",
        redirectURI: URL(string: "com.googleusercontent.apps.123-test:/oauth2redirect")!,
        scopes: ["https://www.googleapis.com/auth/gmail.readonly"], audience: "https://gmail.googleapis.com/")

    static func tokenJSON(access: String, refresh: String? = nil, expiresIn: Int = 3600) -> String {
        var s = #"{"access_token":"\#(access)","expires_in":\#(expiresIn),"token_type":"Bearer""#
        if let refresh { s += #","refresh_token":"\#(refresh)""# }
        return s + "}"
    }

    /// Now + `offset`, in whole seconds: a token set read back from the
    /// store (JSON, seconds since 1970) then compares exactly.
    static func wholeSeconds(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offset).rounded())
    }

    static func expiredSet(_ account: UUID, refresh: String, access: String = "old-access",
                           audience: String = google.audience) -> OAuthTokenSet {
        OAuthTokenSet(accountID: account, issuer: google.issuer, audience: audience, accessToken: access,
                      refreshToken: refresh, expiresAt: wholeSeconds(-10), scopes: google.scopes)
    }
}
