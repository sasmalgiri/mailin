//
//  OAuthSession.swift
//  MailConnectivity
//
//  Plan v4 V4-02 (§3 A10, §4, §7): native OAuth for a public client.
//
//   • PKCE S256 (RFC 7636) and a fresh `state` per sign-in, validated on the
//     callback (and `iss` when the provider sends it, RFC 9207). The pending
//     sign-in is single-use: a second callback, a callback after Cancel, or
//     one for an older attempt is refused — no callback crossover.
//   • application/x-www-form-urlencoded bodies encoded correctly (the old
//     code used `.urlQueryAllowed`, which leaves `+`, `&`, `=` unescaped).
//   • Single-flight refresh per account: N concurrent requests that find the
//     token expiring await ONE refresh; a rotated refresh token is saved as
//     part of one atomic Keychain update of the whole token set; a refused
//     refresh (`invalid_grant`) marks the account as needing reauthorisation
//     and never loops.
//   • Tokens are bound to their account UUID and audience: a Graph token is
//     never handed to an IMAP/SMTP transport (§4, A16).
//   • No client secret: native apps are public clients.
//
//  No networking lives here: the token endpoint is reached through an
//  injected `TokenTransport` (the network-policy gate wraps the real one).
//

import CryptoKit
import Foundation
import Security

// MARK: - Form encoding

public enum FormURLEncoding {
    public static let contentType = "application/x-www-form-urlencoded"

    /// WHATWG application/x-www-form-urlencoded: ALPHA, DIGIT and `*-._`
    /// stay; space becomes `+`; every other UTF-8 byte is %XX.
    public static func encode(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "*"), UInt8(ascii: "-"),
                 UInt8(ascii: "."), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }
}

// MARK: - PKCE and state

public enum OAuthRandom {
    /// base64url (no padding) of `count` random bytes.
    public static func token(bytes count: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw OAuthError.randomGenerationFailed(status) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum PKCE {
    /// 43 characters of the unreserved set (32 random bytes, base64url).
    public static func makeVerifier() throws -> String { try OAuthRandom.token(bytes: 32) }
    public static func challenge(for verifier: String) -> String {
        OAuthRandom.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    public static let method = "S256"
}

// MARK: - Configuration, tokens, errors

public struct OAuthClientConfiguration: Sendable, Equatable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    /// Public native client id — never a client secret.
    public var clientID: String
    public var redirectURI: URL
    public var scopes: [String]
    /// The resource the tokens are for (Graph, Outlook IMAP/SMTP, Gmail API …).
    public var audience: String
    public var extraAuthorizationParameters: [String: String]
    /// Microsoft accepts / expects `scope` on refresh; Google does not need it.
    public var sendsScopeOnRefresh: Bool

    public init(issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, redirectURI: URL,
                scopes: [String], audience: String, extraAuthorizationParameters: [String: String] = [:],
                sendsScopeOnRefresh: Bool = false) {
        self.issuer = issuer; self.authorizationEndpoint = authorizationEndpoint; self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID; self.redirectURI = redirectURI; self.scopes = scopes; self.audience = audience
        self.extraAuthorizationParameters = extraAuthorizationParameters; self.sendsScopeOnRefresh = sendsScopeOnRefresh
    }
}

/// What is stored (one Keychain item per account) — bound to its account and audience.
public struct OAuthTokenSet: Sendable, Equatable, Codable {
    public var accountID: UUID
    public var issuer: String
    public var audience: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]
    public var tokenType: String

    public init(accountID: UUID, issuer: String, audience: String, accessToken: String, refreshToken: String?,
                expiresAt: Date, scopes: [String], tokenType: String = "Bearer") {
        self.accountID = accountID; self.issuer = issuer; self.audience = audience; self.accessToken = accessToken
        self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.scopes = scopes; self.tokenType = tokenType
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> OAuthTokenSet {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(OAuthTokenSet.self, from: data)
    }
}

public enum OAuthError: LocalizedError, Equatable {
    case denied(code: String, description: String?)
    case cancelled
    case stateMismatch
    case callbackMismatch(String)
    case missingCode
    case noPendingAuthorization
    /// `description` keeps the provider's error_description (Microsoft puts
    /// its AADSTS code there) for the app's wording and the log — never shown as is.
    case tokenEndpoint(status: Int, error: String?, description: String? = nil)
    case invalidTokenResponse(String)
    case reauthorisationNeeded(UUID)
    case notRegistered(UUID)
    case credentialReadFailed(String)
    case credentialSaveFailed(String)
    case wrongAccount(expected: UUID, found: UUID)
    case audienceMismatch(expected: String, found: String)
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .denied(let code, let description): return "Sign-in was not allowed (\(code))\(description.map { ": \($0)" } ?? "")."
        case .cancelled: return "Sign-in was cancelled."
        case .stateMismatch: return "The sign-in response did not belong to this sign-in attempt and was ignored."
        case .callbackMismatch(let why): return "The sign-in response came back to the wrong place (\(why)) and was ignored."
        case .missingCode: return "The sign-in response carried no authorisation code."
        case .noPendingAuthorization: return "No sign-in is in progress for this account."
        case .tokenEndpoint(let status, let error, _): return "The provider refused the token request (HTTP \(status)\(error.map { ", \($0)" } ?? ""))."
        case .invalidTokenResponse(let why): return "The provider's token response could not be read: \(why)."
        case .reauthorisationNeeded: return "This account needs you to sign in again."
        case .notRegistered(let id): return "Account \(id.uuidString) has no sign-in configuration."
        case .credentialReadFailed(let why): return "The account's sign-in details could not be read: \(why)"
        case .credentialSaveFailed(let why): return "The account's new sign-in details could not be saved: \(why)"
        case .wrongAccount: return "A stored token belongs to a different account and was not used."
        case .audienceMismatch(let expected, let found): return "The stored token is for \(found), not \(expected), and was not used."
        case .randomGenerationFailed(let status): return "Secure random bytes were unavailable (\(status))."
        }
    }
}

/// The token endpoint, injected (fake in tests, policy-gated URLSession in the app).
/// The transport sets `Content-Type: application/x-www-form-urlencoded`.
public protocol TokenTransport: Sendable {
    func postForm(_ url: URL, body: Data) async throws -> (status: Int, body: Data)
}

struct TokenResponse: Decodable {
    var access_token: String?
    var refresh_token: String?
    var expires_in: Double?
    var scope: String?
    var token_type: String?
    var error: String?
    var error_description: String?
    /// Microsoft: the AADSTS numbers of the refusal (`error_codes: [65001]`).
    var error_codes: [Int]?

    /// error_description, or the AADSTS code alone when only `error_codes` was sent.
    var refusalDescription: String? {
        if let d = error_description, !d.isEmpty { return d }
        return error_codes?.first.map { "AADSTS\($0)" }
    }
}

/// Microsoft's AADSTS number in an error_description ("AADSTS65001: The user
/// or administrator has not consented…"), nil when there is none.
public func microsoftRefusalCode(_ description: String?) -> Int? {
    guard let description, let r = description.range(of: #"AADSTS(\d+)"#, options: .regularExpression) else { return nil }
    return Int(description[r].dropFirst("AADSTS".count))
}

/// Failures to obtain a token that pass by themselves: the network (offline,
/// timeout, dropped connection, DNS), the token endpoint's 5xx / 429, or its
/// `temporarily_unavailable` / `server_error`. The sync engine retries these
/// with backoff instead of failing the run (audit 2026-11-14).
public func isTransientTokenFailure(_ error: Error) -> Bool {
    switch error {
    case MailProviderError.transient, MailProviderError.rateLimited:
        return true
    case OAuthError.tokenEndpoint(let status, let code, _):
        return status == 429 || (500...599).contains(status)
            || ["temporarily_unavailable", "server_error"].contains(code ?? "")
    case let e as URLError:
        return transientURLErrorCodes.contains(e.code)
    default:
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && transientURLErrorCodes.contains(URLError.Code(rawValue: ns.code))
    }
}

let transientURLErrorCodes: Set<URLError.Code> = [
    .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
    .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .badServerResponse, .resourceUnavailable,
    .cannotLoadFromNetwork,
]

/// Token-endpoint errors that mean the grant itself is gone — sign in again.
let reauthorisationErrors: Set<String> = ["invalid_grant", "interaction_required", "consent_required", "login_required"]

func decodeTokenResponse(status: Int, body: Data) throws -> TokenResponse {
    let response: TokenResponse
    do { response = try JSONDecoder().decode(TokenResponse.self, from: body) } catch {
        if (200..<300).contains(status) { throw OAuthError.invalidTokenResponse("not JSON") }
        throw OAuthError.tokenEndpoint(status: status, error: nil)
    }
    guard (200..<300).contains(status), response.error == nil else {
        throw OAuthError.tokenEndpoint(status: status, error: response.error, description: response.refusalDescription)
    }
    guard response.access_token?.isEmpty == false else { throw OAuthError.invalidTokenResponse("no access_token") }
    return response
}

// MARK: - Interactive sign-in

/// One account's interactive sign-in. `begin()` makes the URL to open in
/// the system web-authentication session; `complete(callback:)` validates
/// the redirect and exchanges the code.
public actor OAuthSession {
    public let accountID: UUID
    public let configuration: OAuthClientConfiguration
    let transport: TokenTransport
    let now: @Sendable () -> Date

    struct Pending { var state: String; var verifier: String; var generation: Int }
    private var pending: Pending?
    private var generation = 0

    public init(accountID: UUID, configuration: OAuthClientConfiguration, transport: TokenTransport,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.accountID = accountID; self.configuration = configuration; self.transport = transport; self.now = now
    }

    /// A fresh state and verifier; any earlier attempt becomes invalid.
    public func begin() throws -> URL {
        let state = try OAuthRandom.token()
        let verifier = try PKCE.makeVerifier()
        generation += 1
        pending = Pending(state: state, verifier: verifier, generation: generation)
        guard var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.callbackMismatch("authorization endpoint is not a URL")
        }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
        ]
        items += configuration.extraAuthorizationParameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        // `+` is legal in a query but means space to form decoders: escape it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw OAuthError.callbackMismatch("authorization URL could not be built") }
        return url
    }

    /// The user closed the window, or the app is abandoning the attempt.
    /// A callback arriving afterwards is refused.
    public func cancel() {
        pending = nil
        generation += 1
    }

    public var isPending: Bool { pending != nil }

    /// Validates the redirect and exchanges the code (PKCE verifier, no secret).
    public func complete(callback: URL) async throws -> OAuthTokenSet {
        guard let attempt = pending else { throw OAuthError.noPendingAuthorization }
        let expected = configuration.redirectURI
        guard callback.scheme?.lowercased() == expected.scheme?.lowercased(),
              (callback.host ?? "").lowercased() == (expected.host ?? "").lowercased(),
              callback.path == expected.path else {
            throw OAuthError.callbackMismatch("redirect URI differs")
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // A response for another attempt (or forged) leaves this attempt open.
        guard let state = value("state"), Self.constantTimeEqual(state, attempt.state) else { throw OAuthError.stateMismatch }
        if let iss = value("iss"), iss != configuration.issuer { throw OAuthError.callbackMismatch("issuer differs") }
        // From here the attempt is consumed: single use.
        pending = nil
        if let error = value("error") {
            throw OAuthError.denied(code: error, description: value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        let body = FormURLEncoding.encode([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", expected.absoluteString),
            ("client_id", configuration.clientID),
            ("code_verifier", attempt.verifier),
        ])
        let (status, data) = try await transport.postForm(configuration.tokenEndpoint, body: body)
        // Cancelled (or restarted) while the exchange was in flight: discard.
        guard generation == attempt.generation else { throw OAuthError.cancelled }
        try Task.checkCancellation()
        let response = try decodeTokenResponse(status: status, body: data)
        return OAuthTokenSet(accountID: accountID, issuer: configuration.issuer, audience: configuration.audience,
                             accessToken: response.access_token ?? "", refreshToken: response.refresh_token,
                             expiresAt: now().addingTimeInterval(response.expires_in ?? 3600),
                             scopes: response.scope.map { $0.split(separator: " ").map(String.init) } ?? configuration.scopes,
                             tokenType: response.token_type ?? "Bearer")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

// MARK: - Single-flight refresh

/// Hands out access tokens per account, refreshing at most once at a time
/// per account. Other accounts are never blocked by, or affected by, one
/// account's refresh.
public actor TokenRefreshCoordinator {
    let credentials: CredentialStore
    let transport: TokenTransport
    let now: @Sendable () -> Date
    /// Refresh this long before expiry.
    let skew: TimeInterval

    private var configurations: [UUID: OAuthClientConfiguration] = [:]
    private var cache: [UUID: OAuthTokenSet] = [:]
    /// A refreshed set the Keychain refused; retried before it is used again.
    private var unsaved: Set<UUID> = []
    private var inFlight: [UUID: Task<OAuthTokenSet, Error>] = [:]
    private var needsReauthorisation: Set<UUID> = []
    private var refreshes: [UUID: Int] = [:]
    private let onReauthorisationNeeded: (@Sendable (UUID) async -> Void)?

    public init(credentials: CredentialStore, transport: TokenTransport, skew: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() },
                onReauthorisationNeeded: (@Sendable (UUID) async -> Void)? = nil) {
        self.credentials = credentials; self.transport = transport; self.skew = skew; self.now = now
        self.onReauthorisationNeeded = onReauthorisationNeeded
    }

    public func register(account: UUID, configuration: OAuthClientConfiguration) {
        configurations[account] = configuration
    }

    /// How many refresh requests reached the token endpoint for `account`.
    public func refreshCount(for account: UUID) -> Int { refreshes[account] ?? 0 }

    public func requiresReauthorisation(_ account: UUID) -> Bool { needsReauthorisation.contains(account) }

    /// After an interactive sign-in: saves the whole set (one atomic update)
    /// and clears any reauthorisation mark. Throws if it could not be saved.
    public func store(_ tokens: OAuthTokenSet) throws {
        do { try credentials.write(try tokens.encoded(), kind: .oauthTokenSet, account: tokens.accountID) }
        catch { throw OAuthError.credentialSaveFailed(error.localizedDescription) }
        cache[tokens.accountID] = tokens
        unsaved.remove(tokens.accountID)
        needsReauthorisation.remove(tokens.accountID)
    }

    /// A usable access token for `account`, for `audience` only.
    public func accessToken(for account: UUID, audience: String) async throws -> String {
        try await tokenSet(for: account, audience: audience, forceRefresh: false).accessToken
    }

    /// After the provider rejected a token (HTTP 401): refresh once, shared.
    public func refreshAfterRejection(account: UUID, audience: String) async throws -> String {
        try await tokenSet(for: account, audience: audience, forceRefresh: true).accessToken
    }

    private func tokenSet(for account: UUID, audience: String, forceRefresh: Bool) async throws -> OAuthTokenSet {
        guard !needsReauthorisation.contains(account) else { throw OAuthError.reauthorisationNeeded(account) }
        // Joining a refresh already under way — the single flight.
        if let task = inFlight[account] {
            let set = try await task.value
            try Task.checkCancellation()
            return try checked(set, account: account, audience: audience)
        }
        let current = try currentSet(account)
        _ = try checked(current, account: account, audience: audience)
        if unsaved.contains(account) {
            // The last rotation never reached the Keychain: save it before use.
            do { try credentials.write(try current.encoded(), kind: .oauthTokenSet, account: account); unsaved.remove(account) }
            catch { throw OAuthError.credentialSaveFailed(error.localizedDescription) }
        }
        if !forceRefresh, current.expiresAt > now().addingTimeInterval(skew) { return current }
        let task = Task { try await self.refresh(account: account, from: current) }
        inFlight[account] = task
        defer { inFlight[account] = nil }
        let set = try await task.value
        try Task.checkCancellation()
        return try checked(set, account: account, audience: audience)
    }

    private func checked(_ set: OAuthTokenSet, account: UUID, audience: String) throws -> OAuthTokenSet {
        guard set.accountID == account else { throw OAuthError.wrongAccount(expected: account, found: set.accountID) }
        guard set.audience == audience else { throw OAuthError.audienceMismatch(expected: audience, found: set.audience) }
        return set
    }

    private func currentSet(_ account: UUID) throws -> OAuthTokenSet {
        if let cached = cache[account] { return cached }
        let data: Data?
        do { data = try credentials.read(.oauthTokenSet, account: account) }
        catch { throw OAuthError.credentialReadFailed(error.localizedDescription) }
        guard let data else { throw OAuthError.reauthorisationNeeded(account) }
        let set: OAuthTokenSet
        do { set = try OAuthTokenSet.decode(data) } catch { throw OAuthError.credentialReadFailed("the stored token set is unreadable") }
        cache[account] = set
        return set
    }

    private func refresh(account: UUID, from current: OAuthTokenSet) async throws -> OAuthTokenSet {
        guard let configuration = configurations[account] else { throw OAuthError.notRegistered(account) }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            try await markNeedsReauthorisation(account)
            throw OAuthError.reauthorisationNeeded(account)
        }
        var form: [(String, String)] = [("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                                        ("client_id", configuration.clientID)]
        if configuration.sendsScopeOnRefresh { form.append(("scope", configuration.scopes.joined(separator: " "))) }
        refreshes[account, default: 0] += 1
        let (status, body) = try await transport.postForm(configuration.tokenEndpoint, body: FormURLEncoding.encode(form))
        let response: TokenResponse
        do { response = try decodeTokenResponse(status: status, body: body) } catch OAuthError.tokenEndpoint(let code, let error, let description) {
            if let error, reauthorisationErrors.contains(error) {
                try await markNeedsReauthorisation(account)
                throw OAuthError.reauthorisationNeeded(account)
            }
            throw OAuthError.tokenEndpoint(status: code, error: error, description: description)
        }
        let next = OAuthTokenSet(accountID: account, issuer: current.issuer, audience: current.audience,
                                 accessToken: response.access_token ?? "",
                                 // Rotation: keep the new refresh token, or the old one if none was sent.
                                 refreshToken: response.refresh_token ?? current.refreshToken,
                                 expiresAt: now().addingTimeInterval(response.expires_in ?? 3600),
                                 scopes: response.scope.map { $0.split(separator: " ").map(String.init) } ?? current.scopes,
                                 tokenType: response.token_type ?? current.tokenType)
        // The new set is usable in memory even if the Keychain refuses it, so
        // the provider's rotation is not lost; the failure is thrown and the
        // save retried before the set is used again. The Keychain item is
        // updated in place, so a refused write leaves the previous set intact.
        cache[account] = next
        do { try credentials.write(try next.encoded(), kind: .oauthTokenSet, account: account) }
        catch {
            unsaved.insert(account)
            throw OAuthError.credentialSaveFailed(error.localizedDescription)
        }
        unsaved.remove(account)
        return next
    }

    private func markNeedsReauthorisation(_ account: UUID) async throws {
        needsReauthorisation.insert(account)
        cache[account] = nil
        await onReauthorisationNeeded?(account)
    }
}
