//
//  GmailOAuth.swift
//  MailConnectivity
//
//  Plan v4 V4-05 (§3 A03, §4): Google sign-in for the Gmail connector.
//   • Google's own endpoints; PKCE S256 + state through `OAuthSession`; no
//     client secret (a native app is a public client).
//   • The client ID is INJECTED (from the app's build configuration) — never
//     hard-coded here — and a placeholder ID is refused before any sign-in
//     window opens (the old connector shipped
//     "YOUR_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com").
//   • Minimal scope: capture needs `gmail.readonly` only. Sending and
//     server actions request their own scopes when those features are used.
//

import Foundation

public enum GmailOAuth {
    public static let issuer = "https://accounts.google.com"
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// The token endpoint host the network policy is asked about before a refresh.
    public static let tokenHost = "oauth2.googleapis.com"
    /// The audience Gmail API tokens are bound to (never handed to IMAP/SMTP).
    public static let audience = "https://gmail.googleapis.com/"
    /// Read-only capture: the one restricted scope it needs.
    public static let readOnlyScope = "https://www.googleapis.com/auth/gmail.readonly"
    public static let captureScopes = [readOnlyScope]

    public enum ConfigurationError: LocalizedError, Equatable {
        case missingClientID
        case placeholderClientID(String)
        case malformedClientID(String)
        case redirectMismatch(String)
        case scopeNotAllowed(String)

        public var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Gmail sign-in is not configured in this build (no Google client ID)."
            case .placeholderClientID:
                return "Gmail sign-in is not configured in this build (the Google client ID is a placeholder)."
            case .malformedClientID:
                return "Gmail sign-in is not configured correctly (the Google client ID is not a native client ID)."
            case .redirectMismatch(let why):
                return "Gmail sign-in is not configured correctly (\(why))."
            case .scopeNotAllowed(let scope):
                return "Gmail sign-in may not request the permission \(scope)."
            }
        }
    }

    static let placeholderMarkers = ["your", "placeholder", "client_id", "clientid", "example", "xxxx", "todo",
                                     "changeme", "replace", "dummy", "<", ">", "{", "}", "$("]

    /// Validates a Google native (iOS / macOS) OAuth client ID:
    /// `<project number>-<id>.apps.googleusercontent.com`.
    public static func validateClientID(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ConfigurationError.missingClientID }
        let lower = id.lowercased()
        if placeholderMarkers.contains(where: { lower.contains($0) }) { throw ConfigurationError.placeholderClientID(id) }
        let suffix = ".apps.googleusercontent.com"
        guard lower == id, id.hasSuffix(suffix) else { throw ConfigurationError.malformedClientID(id) }
        let head = id.dropLast(suffix.count)
        let parts = head.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count >= 6, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[0].contains(where: { $0 != "0" }),
              parts[1].count >= 16, parts[1].allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }),
              Set(parts[1]).count > 4 else {
            throw ConfigurationError.malformedClientID(id)
        }
        return id
    }

    /// Google's redirect for a native client: the reversed client ID scheme.
    public static func defaultRedirectURI(clientID: String) throws -> URL {
        let id = try validateClientID(clientID)
        let prefix = id.dropLast(".apps.googleusercontent.com".count)
        guard let url = URL(string: "com.googleusercontent.apps.\(prefix):/oauth2redirect") else {
            throw ConfigurationError.malformedClientID(id)
        }
        return url
    }

    /// The OAuth configuration for Gmail capture. `redirectURI` defaults to
    /// the reversed-client-ID scheme; a custom-scheme redirect must use that
    /// scheme (Google refuses others for native clients).
    public static func configuration(clientID: String, redirectURI: URL? = nil,
                                     scopes: [String] = captureScopes) throws -> OAuthClientConfiguration {
        let id = try validateClientID(clientID)
        let expected = try defaultRedirectURI(clientID: id)
        let redirect = redirectURI ?? expected
        if let scheme = redirect.scheme?.lowercased(), scheme != "http", scheme != "https",
           scheme != expected.scheme?.lowercased() {
            throw ConfigurationError.redirectMismatch("the redirect scheme must be \(expected.scheme ?? "")")
        }
        if let scheme = redirect.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // Loopback only (RFC 8252 §7.3) — never a remote web redirect.
            guard scheme == "http", let host = redirect.host, ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host) else {
                throw ConfigurationError.redirectMismatch("a web redirect must be a loopback address")
            }
        }
        guard !scopes.isEmpty else { throw ConfigurationError.scopeNotAllowed("(none)") }
        if let other = scopes.first(where: { !$0.hasPrefix("https://www.googleapis.com/auth/gmail.") }) {
            throw ConfigurationError.scopeNotAllowed(other)
        }
        return OAuthClientConfiguration(issuer: issuer, authorizationEndpoint: authorizationEndpoint,
                                        tokenEndpoint: tokenEndpoint, clientID: id, redirectURI: redirect,
                                        scopes: scopes, audience: audience)
    }

    /// One account's interactive Google sign-in (PKCE + state, single use).
    public static func makeSession(accountID: UUID, clientID: String, redirectURI: URL? = nil,
                                   transport: TokenTransport,
                                   now: @escaping @Sendable () -> Date = { Date() }) throws -> OAuthSession {
        OAuthSession(accountID: accountID, configuration: try configuration(clientID: clientID, redirectURI: redirectURI),
                     transport: transport, now: now)
    }
}
