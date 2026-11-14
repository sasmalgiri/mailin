//
//  ConnectedMailProductionTransports.swift
//  maxmailin
//
//  Plan v4 V4-13: the Mail workspace's network-touching parts — interactive
//  OAuth sign-in (ASWebAuthenticationSession, PKCE + state, ephemeral browser
//  session), the send routes and the server-action executors. Compiled ONLY
//  in the connected build; the offline build contains none of it.
//
//  Every request still asks `MailNetworkPolicy` first: the token exchange
//  goes through `PolicyCheckedTokenTransport`, which refuses any sign-in host
//  the account was not granted; for the duration of a sign-in the account is
//  granted its provider's sign-in host and nothing else.
//

#if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD
@testable import ArchiveCore
import AuthenticationServices
import Foundation
import MailConnectivity
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class ConnectedMailProductionTransports: ConnectedMailTransports {
    private var webSession: ASWebAuthenticationSession?
    private let anchor = WebSignInAnchor()

    // MARK: Sign-in

    func signIn(_ choice: MailProviderChoice, accountID: UUID, extraScopes: [String], info: [String: String],
                policy: MailNetworkPolicy) async throws -> (tokens: OAuthTokenSet, issuer: String, tenant: String?) {
        var configuration: OAuthClientConfiguration
        var tenant: String?
        switch choice {
        case .gmail:
            configuration = try GmailOAuth.configuration(clientID: info[MailProviderChoice.gmailClientIDKey] ?? "",
                                                         scopes: GmailOAuth.captureScopes + extraScopes.filter { $0 != GmailOAuth.readOnlyScope })
        case .outlook:
            guard let redirect = URL(string: info[MailProviderChoice.graphRedirectKey] ?? "") else {
                throw MailWorkspaceError(MailProviderChoice.notConfiguredReason(.outlook))
            }
            let settings = GraphSignInSettings(clientID: info[MailProviderChoice.graphClientIDKey] ?? "", tenant: "common", redirectURI: redirect)
            configuration = try GraphOAuth.configuration(settings)
            let resource = GraphAudience.resource()
            for scope in extraScopes {
                let full = scope.hasPrefix("https://") ? scope : "\(resource)/\(scope)"
                if !configuration.scopes.contains(full) { configuration.scopes.insert(full, at: 0) }
            }
            tenant = settings.tenant
        default:
            throw MailWorkspaceError(String(localized: "This account signs in with a password, not in the browser."))
        }

        // Grant this account its sign-in host only, for the exchange.
        let host = configuration.tokenEndpoint.host ?? ""
        var grant = policy.account(accountID) ?? MailAccountNetworkPolicy(id: accountID)
        grant.isEnabled = true
        grant.authorizationHosts.insert(host)
        policy.setAccount(grant)

        let session = OAuthSession(accountID: accountID, configuration: configuration,
                                   transport: PolicyCheckedTokenTransport(policy: policy))
        let url = try await session.begin()
        let callback: URL
        do {
            callback = try await present(url, callbackScheme: configuration.redirectURI.scheme ?? "")
        } catch {
            await session.cancel()
            throw error
        }
        let tokens = try await session.complete(callback: callback)
        return (tokens, configuration.issuer, tenant)
    }

    private func present(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = true
            webSession = session
            if !session.start() { continuation.resume(throwing: OAuthError.cancelled) }
        }
    }

    // MARK: Confirmed address

    /// Gmail states the mailbox's own address (users.getProfile, allowed by
    /// the read-only scope the sign-in already holds). The read asks the policy
    /// like every capture request: for its duration the account may read
    /// (purpose Preserve mail) from the Gmail API host only, then the grant
    /// is put back as it was. Microsoft Graph states the address from `/me`
    /// with User.Read, which the Outlook sign-in requests (owner 2026-11-13).
    func confirmedAddress(_ choice: MailProviderChoice, accountID: UUID, tokens: OAuthTokenSet,
                          policy: MailNetworkPolicy) async -> String? {
        let host: String
        switch choice {
        case .gmail: host = GmailAPI.host
        case .outlook: host = GraphSignInSettings.defaultGraphHost
        default: return nil
        }
        let previous = policy.account(accountID)
        var grant = previous ?? MailAccountNetworkPolicy(id: accountID)
        let alreadyAllowed = grant.isEnabled && grant.modes.contains(.preserveMail) && grant.mailHosts.contains(host)
        if !alreadyAllowed {
            grant.isEnabled = true
            grant.modes.insert(.preserveMail)
            grant.mailHosts.insert(host)
            policy.setAccount(grant)
        }
        let context = ProviderRequestContext(accountID: accountID, accessToken: tokens.accessToken, attempt: 0)
        let permission = ConnectedMailRuntime.permission(policy: policy)
        let address: String?
        if choice == .gmail {
            let adapter = GmailAdapter(accountID: accountID, transport: URLSessionGmailTransport(), permission: permission)
            address = Self.providerStated(try? await adapter.profileAddress(context: context))
            await adapter.close()
        } else {
            let adapter = GraphAdapter(accountID: accountID, transport: URLSessionGraphTransport(), permission: permission)
            address = Self.providerStated(try? await adapter.profileAddress(context: context))
            await adapter.close()
        }
        if !alreadyAllowed { policy.setAccount(previous ?? MailAccountNetworkPolicy(id: accountID)) }
        return address
    }

    /// The mailbox address in a provider's profile answer, or nil when it does
    /// not confirm one. A plain string is the stated address. A structured
    /// answer counts only when it does not say the address came from the
    /// sign-in name alone (Graph `userPrincipalName` is a login, not a
    /// mailbox): a Bool child named like "confirmed" that is false, or one
    /// named like "userPrincipalName" / "fromSignInName" that is true, makes
    /// it unconfirmed. Works with either form of `profileAddress`.
    nonisolated static func providerStated(_ answer: Any?) -> String? {
        guard let answer else { return nil }
        if let text = answer as? String { return text }
        var address: String?
        var unconfirmed = false
        var pending: [Any] = [answer]
        while let value = pending.popLast() {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                pending.append(contentsOf: mirror.children.map(\.value))
                continue
            }
            for child in mirror.children {
                let label = (child.label ?? "").lowercased()
                switch child.value {
                case let flag as Bool:
                    if label.contains("confirm") || label.contains("verified") || label.contains("mailbox") {
                        if !flag { unconfirmed = true }
                    } else if label.contains("principal") || label.contains("signin") || label.contains("login") || label.contains("upn") {
                        if flag { unconfirmed = true }
                    }
                case let text as String where address == nil && (label.contains("address") || label.contains("mail") || label.isEmpty):
                    address = text
                default:
                    if Mirror(reflecting: child.value).displayStyle == .enum, label.contains("source") || label.contains("origin") {
                        let described = String(describing: child.value).lowercased()
                        if described.contains("principal") || described.contains("upn") { unconfirmed = true }
                    }
                }
            }
        }
        return unconfirmed ? nil : address
    }

    // MARK: Login check

    /// One IMAP session and, when an outgoing server is set, one SMTP session
    /// up to AUTH. For their duration the account may reach exactly those two
    /// hosts; the policy is put back as it was afterwards.
    func verifyLogin(_ account: MailAccount, password: String, smtp: MailAccountExtras.SMTP?,
                     policy: MailNetworkPolicy) async throws {
        guard account.provider == .imap, let host = account.host else { return }
        let previous = policy.account(account.id)
        var grant = previous ?? MailAccountNetworkPolicy(id: account.id)
        grant.isEnabled = true
        grant.modes.insert(.preserveMail)
        grant.modes.insert(.sendMail)
        grant.mailHosts.insert(host)
        if let smtp { grant.mailHosts.insert(smtp.host) }
        policy.setAccount(grant)
        defer {
            if let previous { policy.setAccount(previous) } else { policy.removeAccount(account.id) }
        }
        try await IMAPLoginCheck.verify(account, password: password, permission: ConnectedMailRuntime.permission(policy: policy))
        if let smtp {
            let settings = SMTPServerSettings(host: smtp.host, port: smtp.port, security: smtp.implicitTLS ? .implicitTLS : .startTLS,
                                              connectTimeout: 30, commandTimeout: 60)
            try await SMTPLoginCheck.verify(settings, username: account.loginName ?? account.displayIdentity, password: password,
                                            accountID: account.id,
                                            permission: ConnectedMailBackend.permission(policy: policy, purpose: .sendMail))
        }
    }

    // MARK: Sending

    func registerSending(_ account: MailAccount, extras: MailAccountExtras, outbox: Outbox,
                         credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                         permission: @escaping NetworkPermission) async {
        switch account.provider {
        case .gmail:
            guard let tokens else { return }
            await outbox.register(account: account.id, submitter: GmailSendSubmitter(
                tokens: tokens, transport: NoRedirectSendHTTPTransport(), permission: permission))
        case .microsoftGraph:
            guard let tokens else { return }
            await outbox.register(account: account.id, submitter: GraphSendSubmitter(
                tokens: tokens, transport: NoRedirectSendHTTPTransport(), permission: permission))
        case .imap:
            guard let smtp = extras.smtp else { return }
            let settings = SMTPServerSettings(host: smtp.host, port: smtp.port, security: smtp.implicitTLS ? .implicitTLS : .startTLS)
            await outbox.register(account: account.id, submitter: SMTPSubmitter(
                settings: settings,
                credentials: .password(username: account.loginName ?? account.displayIdentity, store: credentials),
                permission: permission))
        }
    }

    // MARK: Server actions

    func actionExecutor(_ account: MailAccount, credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                        permission: @escaping NetworkPermission) throws -> (any RemoteActionExecutor)? {
        switch account.provider {
        case .gmail:
            guard let tokens else { return nil }
            return GmailActionExecutor(accountID: account.id, tokens: tokens, transport: NoRedirectSendHTTPTransport(), permission: permission)
        case .microsoftGraph:
            guard let tokens else { return nil }
            return GraphActionExecutor(accountID: account.id, tokens: tokens, transport: NoRedirectSendHTTPTransport(), permission: permission)
        case .imap:
            let adapter = try IMAPAdapter(account: account, credentials: credentials, permission: permission)
            return IMAPActionExecutor(adapter: adapter, trashMailbox: nil, permission: permission)
        }
    }

    /// As above, with the Trash folder the IMAP server listed (special use \Trash).
    func actionExecutor(_ account: MailAccount, credentials: any CredentialStore, tokens: TokenRefreshCoordinator?,
                        permission: @escaping NetworkPermission, trashMailbox: String?) throws -> (any RemoteActionExecutor)? {
        guard account.provider == .imap else {
            return try actionExecutor(account, credentials: credentials, tokens: tokens, permission: permission)
        }
        let adapter = try IMAPAdapter(account: account, credentials: credentials, permission: permission)
        return IMAPActionExecutor(adapter: adapter, trashMailbox: trashMailbox, permission: permission)
    }
}

/// Where the sign-in window attaches: the app's key window.
private final class WebSignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
        #endif
    }
}
#endif
