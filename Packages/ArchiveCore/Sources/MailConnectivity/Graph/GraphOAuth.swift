//
//  GraphOAuth.swift
//  MailConnectivity
//
//  Plan v4 V4-06 (§4, §3 A16): the Microsoft identity platform sign-in for
//  the Graph capture connector.
//
//   • Public native client, authorization code + PKCE S256 (`OAuthSession`),
//     no client secret. The client ID is injected by the app (the owner's
//     Entra app registration); an empty / placeholder / all-zero ID is
//     refused here, so a build without a real registration cannot start a
//     sign-in.
//   • Tenant / authority configurable: `common`, `organizations`,
//     `consumers`, a tenant GUID or a verified domain; the authority host
//     defaults to login.microsoftonline.com.
//   • Capture asks for delegated `Mail.Read` (+ `Mail.Read.Shared` only when
//     shared / delegated mailboxes are wanted), `User.Read` (only so the
//     account's own address can be read from `/me` and the account is named
//     by Microsoft's answer, never by what was typed — owner 2026-11-13) and
//     `offline_access`. Nothing else: sending, writing and server actions are
//     separate grants.
//   • A Graph token is for Graph ONLY. Exchange protocol resources
//     (IMAP / POP / SMTP / EWS on outlook.office.com / outlook.office365.com)
//     have their own scopes and tokens; a scope for them is refused in a
//     Graph configuration, the coordinator binds the token set to the Graph
//     audience, and the adapter refuses to send a JWT whose `aud` is not Graph.
//

import Foundation

public enum GraphAudience {
    /// The audience the Graph adapter asks the token coordinator for.
    public static func resource(graphHost: String = GraphSignInSettings.defaultGraphHost) -> String { "https://\(graphHost)" }

    /// `aud` values of a Microsoft Graph access token.
    static func acceptedJWTAudiences(graphHost: String) -> Set<String> {
        ["https://\(graphHost)", "https://\(graphHost)/", "00000003-0000-0000-c000-000000000000"]
    }

    /// Exchange protocol resources (IMAP, POP, SMTP AUTH, EWS): never a Graph token.
    static let exchangeProtocolResources: [String] = [
        "https://outlook.office.com", "https://outlook.office365.com", "00000002-0000-0ff1-ce00-000000000000",
    ]
    static let exchangeProtocolPermissions: [String] = [
        "imap.accessasuser.all", "pop.accessasuser.all", "smtp.send", "ews.accessasuser.all",
    ]
}

public struct GraphSignInSettings: Sendable, Equatable {
    public static let defaultAuthorityHost = "login.microsoftonline.com"
    public static let defaultGraphHost = "graph.microsoft.com"

    /// The Entra app registration's Application (client) ID — supplied by the owner.
    public var clientID: String
    /// `common`, `organizations`, `consumers`, a tenant GUID or a domain.
    public var tenant: String
    /// The redirect URI registered for the public client (e.g. `msauth.<bundle id>://auth`).
    public var redirectURI: URL
    public var authorityHost: String
    public var graphHost: String
    /// Adds `Mail.Read.Shared` so shared / delegated mailboxes can be read where permitted.
    public var sharedMailboxes: Bool

    public init(clientID: String, tenant: String = "common", redirectURI: URL,
                authorityHost: String = GraphSignInSettings.defaultAuthorityHost,
                graphHost: String = GraphSignInSettings.defaultGraphHost, sharedMailboxes: Bool = false) {
        self.clientID = clientID; self.tenant = tenant; self.redirectURI = redirectURI
        self.authorityHost = authorityHost; self.graphHost = graphHost; self.sharedMailboxes = sharedMailboxes
    }
}

public enum GraphConfigurationError: LocalizedError, Equatable {
    case placeholderClientID(String)
    case invalidTenant(String)
    case invalidRedirectURI(String)
    case invalidHost(String)
    case foreignScope(String)
    case tokenAudience(String)

    public var errorDescription: String? {
        switch self {
        case .placeholderClientID(let id):
            return "The Microsoft sign-in has no real app registration (client ID \"\(id)\"). Outlook capture stays off until one is configured."
        case .invalidTenant(let t): return "\"\(t)\" is not a Microsoft tenant (use common, organizations, consumers, a tenant ID or a domain)."
        case .invalidRedirectURI(let why): return "The Microsoft sign-in redirect address is not usable: \(why)."
        case .invalidHost(let h): return "\"\(h)\" is not a host name."
        case .foreignScope(let s): return "The scope \(s) is not a Microsoft Graph mail-reading permission and is not requested by the Graph connection."
        case .tokenAudience(let aud): return "The access token is for \(aud), not Microsoft Graph, and was not sent."
        }
    }
}

public enum GraphOAuth {
    /// Client IDs that are obviously not a registration.
    static let placeholderIDs: Set<String> = [
        "", "00000000-0000-0000-0000-000000000000", "your_client_id", "your-client-id", "client_id", "client-id",
        "<client-id>", "<client_id>", "replace-me", "todo", "placeholder", "changeme",
    ]

    static func isGUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    static func validHost(_ h: String) -> Bool {
        !h.isEmpty && h.count <= 253 && h.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            && !h.hasPrefix(".") && !h.hasPrefix("-") && h.contains(".")
    }

    public static func validateClientID(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !placeholderIDs.contains(lowered), !lowered.contains("your"), !lowered.contains("placeholder"),
              isGUID(trimmed), trimmed == id else {
            throw GraphConfigurationError.placeholderClientID(id)
        }
    }

    public static func validateTenant(_ tenant: String) throws {
        if ["common", "organizations", "consumers"].contains(tenant) || isGUID(tenant) || validHost(tenant) { return }
        throw GraphConfigurationError.invalidTenant(tenant)
    }

    /// Graph mail-reading permissions only (plus the OpenID / refresh scopes).
    public static func validateScopes(_ scopes: [String], graphHost: String = GraphSignInSettings.defaultGraphHost) throws {
        let prefix = "https://\(graphHost.lowercased())/"
        let allowed: Set<String> = ["mail.read", "mail.read.shared", "user.read"]
        for scope in scopes {
            let s = scope.lowercased()
            if ["offline_access", "openid", "profile", "email"].contains(s) { continue }
            guard s.hasPrefix(prefix), allowed.contains(String(s.dropFirst(prefix.count))) else {
                throw GraphConfigurationError.foreignScope(scope)
            }
        }
    }

    /// The OAuth client configuration for capture. Throws for a placeholder
    /// client ID, a malformed tenant / host / redirect URI.
    public static func configuration(_ settings: GraphSignInSettings) throws -> OAuthClientConfiguration {
        try validateClientID(settings.clientID)
        try validateTenant(settings.tenant)
        guard validHost(settings.authorityHost) else { throw GraphConfigurationError.invalidHost(settings.authorityHost) }
        guard validHost(settings.graphHost) else { throw GraphConfigurationError.invalidHost(settings.graphHost) }
        let redirect = settings.redirectURI
        guard let scheme = redirect.scheme?.lowercased(), !scheme.isEmpty else {
            throw GraphConfigurationError.invalidRedirectURI("it has no scheme")
        }
        if scheme == "http", !["localhost", "127.0.0.1"].contains(redirect.host ?? "") {
            throw GraphConfigurationError.invalidRedirectURI("plain http is only allowed for localhost")
        }
        if redirect.absoluteString.lowercased().contains("your") || redirect.absoluteString.contains("<") {
            throw GraphConfigurationError.invalidRedirectURI("it is a placeholder")
        }
        let resource = GraphAudience.resource(graphHost: settings.graphHost)
        var scopes = ["\(resource)/Mail.Read"]
        if settings.sharedMailboxes { scopes.append("\(resource)/Mail.Read.Shared") }
        scopes.append("\(resource)/User.Read")
        scopes.append("offline_access")
        try validateScopes(scopes, graphHost: settings.graphHost)
        let authority = "https://\(settings.authorityHost)/\(settings.tenant)"
        guard let authorize = URL(string: "\(authority)/oauth2/v2.0/authorize"),
              let token = URL(string: "\(authority)/oauth2/v2.0/token") else {
            throw GraphConfigurationError.invalidTenant(settings.tenant)
        }
        return OAuthClientConfiguration(
            issuer: "\(authority)/v2.0", authorizationEndpoint: authorize, tokenEndpoint: token,
            clientID: settings.clientID, redirectURI: redirect, scopes: scopes, audience: resource,
            extraAuthorizationParameters: ["response_mode": "query", "prompt": "select_account"],
            sendsScopeOnRefresh: true)
    }

    /// Refuses an access token whose JWT `aud` is not Microsoft Graph (an
    /// Outlook IMAP / SMTP / EWS token, for example). Consumer-account tokens
    /// are opaque, not JWTs: for those the coordinator's audience binding of
    /// the stored token set is the guard.
    public static func checkAudience(ofAccessToken token: String,
                                     graphHost: String = GraphSignInSettings.defaultGraphHost) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let audiences: [String]
        if let one = object["aud"] as? String { audiences = [one] } else if let many = object["aud"] as? [String] { audiences = many } else { return }
        let accepted = GraphAudience.acceptedJWTAudiences(graphHost: graphHost.lowercased())
        guard audiences.contains(where: { accepted.contains($0.lowercased()) }) else {
            throw GraphConfigurationError.tokenAudience(audiences.joined(separator: ", "))
        }
    }
}
