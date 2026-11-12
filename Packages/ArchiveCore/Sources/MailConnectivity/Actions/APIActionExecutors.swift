//
//  APIActionExecutors.swift
//  MailConnectivity
//
//  Plan v4 V4-11: Gmail and Microsoft Graph server actions over an injected
//  `SendHTTPTransport` (the transport must not follow redirects —
//  `NoRedirectSendHTTPTransport` is the app's).
//
//   Gmail (users.messages, https://gmail.googleapis.com/gmail/v1/users/me/):
//     GET  messages/{id}?format=minimal          state (labelIds)
//     POST messages/{id}/modify                  read/unread (UNREAD), flag (STARRED),
//                                                labels, move (remove from + add to),
//                                                server Archive (remove INBOX)
//     POST messages/{id}/trash | /untrash         Trash / restore
//   Graph (/v1.0/me or /v1.0/users/{upn}, Prefer: IdType="ImmutableId"):
//     GET   messages/{id}?$select=…              state (isRead, flag, parentFolderId)
//     PATCH messages/{id}                        isRead, flag.flagStatus
//     POST  messages/{id}/move {destinationId}   move, Deleted Items, restore
//     GET   mailFolders/{well-known name}        name → id (deleteditems, inbox …)
//
//  Every request: the network policy is asked first (the token endpoint
//  first of all), the bearer token goes to the provider's host only, a 401
//  refreshes the token once, nothing is retried silently.
//

import ArchiveCore
import Foundation

// MARK: - Shared HTTP core

struct RemoteActionHTTP: Sendable {
    let accountID: UUID
    let host: String
    let authorizationHost: String
    let audience: String
    let changeScope: String
    let tokens: any AccessTokenSource
    let transport: any SendHTTPTransport
    let permission: NetworkPermission
    var extraHeaders: [String: String] = [:]
    var tokenCheck: (@Sendable (String) throws -> Void)?
    /// Error codes / reasons meaning "the token lacks the change scope".
    var scopeReasons: Set<String> = []

    private func token(refresh: Bool) async throws -> String {
        do {
            try permission(NetworkAsk(accountID: accountID, host: authorizationHost, destination: .authorization, operation: .oauthRefresh))
        } catch { throw RemoteRequestFailure.notSent(.networkNotPermitted(error.localizedDescription)) }
        let token: String
        do {
            token = refresh ? try await tokens.refreshAfterRejection(account: accountID, audience: audience)
                            : try await tokens.accessToken(for: accountID, audience: audience)
        } catch OAuthError.reauthorisationNeeded {
            throw RemoteRequestFailure.notSent(.needsSignIn)
        } catch {
            throw RemoteRequestFailure.notSent(.stateUnavailable("a sign-in token could not be obtained: \(error.localizedDescription)"))
        }
        if let tokenCheck {
            do { try tokenCheck(token) } catch { throw RemoteRequestFailure.notSent(.needsSignIn) }
        }
        return token
    }

    /// One request (plus one repeat after a 401). Returns a 2xx response.
    func send(_ method: String, _ url: URL, json: Data? = nil, mutating: Bool) async throws -> SendHTTPResponse {
        guard url.scheme == "https", url.host?.lowercased() == host, url.port == nil else {
            throw RemoteRequestFailure.notSent(.unsupported("mailin refused to send this account's token to \(url.host ?? "another host")"))
        }
        var bearer = try await token(refresh: false)
        var refreshed = false
        while true {
            try Task.checkCancellation()
            do {
                try permission(NetworkAsk(accountID: accountID, host: host, destination: .mailServer, operation: refreshed ? .retry : .request))
            } catch { throw RemoteRequestFailure.notSent(.networkNotPermitted(error.localizedDescription)) }
            var headers = extraHeaders
            headers["Authorization"] = "Bearer \(bearer)"
            headers["Accept"] = "application/json"
            if json != nil { headers["Content-Type"] = "application/json" }
            let response: SendHTTPResponse
            do {
                response = try await transport.perform(SendHTTPRequest(method: method, url: url, headers: headers, body: json ?? Data()))
            } catch let notSent as NotSentError {
                throw RemoteRequestFailure.notSent(.stateUnavailable("could not reach \(host): \(notSent.reason)"))
            } catch is CancellationError {
                throw mutating ? RemoteRequestFailure.uncertain("the request was stopped before its reply") : CancellationError()
            } catch {
                throw RemoteRequestFailure.uncertain("the connection to \(host) failed before its reply (\(error.localizedDescription))")
            }
            if response.status == 401 && !refreshed {
                refreshed = true
                bearer = try await token(refresh: true)
                continue
            }
            return try check(response, mutating: mutating)
        }
    }

    private func check(_ r: SendHTTPResponse, mutating: Bool) throws -> SendHTTPResponse {
        if (200..<300).contains(r.status) { return r }
        let detail = Self.detail(r)
        switch r.status {
        case 401: throw RemoteRequestFailure.notSent(.needsSignIn)
        case 300..<400: throw RemoteRequestFailure.refused("\(host) redirected the request (HTTP \(r.status)); the redirect was not followed")
        case 403:
            if !Self.reasons(r).isDisjoint(with: scopeReasons) { throw RemoteRequestFailure.notSent(.needsExtraPermission(scope: changeScope)) }
            throw RemoteRequestFailure.refused(detail)
        case 404, 410: throw RemoteRequestFailure.gone
        case 429: throw RemoteRequestFailure.refused("\(host) asked mailin to slow down (\(detail)); nothing was changed")
        case 400..<500: throw RemoteRequestFailure.refused(detail)
        default:
            if mutating { throw RemoteRequestFailure.uncertain("\(host) answered \(detail) — the change may or may not have been made") }
            throw RemoteRequestFailure.refused(detail)
        }
    }

    struct ErrorBody: Decodable {
        struct Reason: Decodable { var reason: String? }
        struct Inner: Decodable { var code: AnyCode?; var message: String?; var status: String?; var errors: [Reason]? }
        var error: Inner?
    }
    /// Gmail sends a numeric `code`, Graph a string one.
    struct AnyCode: Decodable {
        var text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { text = s } else if let n = try? c.decode(Int.self) { text = String(n) } else { text = "" }
        }
    }

    static func reasons(_ r: SendHTTPResponse) -> Set<String> {
        guard let e = (try? JSONDecoder().decode(ErrorBody.self, from: r.body))?.error else { return [] }
        var out = Set((e.errors ?? []).compactMap(\.reason))
        if let c = e.code?.text { out.insert(c) }
        if let s = e.status { out.insert(s) }
        return out
    }

    static func detail(_ r: SendHTTPResponse) -> String {
        let e = (try? JSONDecoder().decode(ErrorBody.self, from: r.body))?.error
        return "HTTP \(r.status)" + (e?.message.map { ": \($0)" } ?? "")
    }

    static func jsonBody(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: - Gmail

public struct GmailActionExecutor: RemoteActionExecutor {
    public let accountID: UUID
    public let provider: MailProviderKind = .gmail
    public static let base = "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
    let http: RemoteActionHTTP

    public init(accountID: UUID, tokens: any AccessTokenSource, transport: any SendHTTPTransport,
                permission: @escaping NetworkPermission, audience: String = GmailOAuth.audience,
                authorizationHost: String = GmailOAuth.tokenHost) {
        self.accountID = accountID
        http = RemoteActionHTTP(accountID: accountID, host: GmailAPI.host, authorizationHost: authorizationHost, audience: audience,
                                changeScope: ServerActionScopes.gmailModify, tokens: tokens, transport: transport, permission: permission,
                                scopeReasons: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"])
    }

    struct Minimal: Decodable { var id: String?; var labelIds: [String]?; var historyId: String? }

    private func id(_ identity: ProviderMessageIdentity) throws -> String {
        guard case .gmail(let id) = identity else { throw RemoteRequestFailure.notSent(.accountMismatch) }
        guard GmailAPI.isSafeID(id) else { throw RemoteRequestFailure.notSent(.unsupported("The Gmail message id is malformed.")) }
        return id
    }

    private func url(_ path: String, _ query: String = "") throws -> URL {
        guard let u = URL(string: Self.base + path + query) else { throw RemoteRequestFailure.notSent(.unsupported("a Gmail address could not be built")) }
        return u
    }

    public func resolve(_ request: RemoteChangeRequest, precondition: RemotePrecondition,
                        for identity: ProviderMessageIdentity) async throws -> ResolvedChange {
        _ = try id(identity)
        func label(_ l: String) throws {
            guard GmailAPI.isSafeID(l) else { throw RemoteRequestFailure.notSent(.unsupported("“\(l)” is not a Gmail label id.")) }
            guard l != "TRASH", l != "SPAM" else {
                throw RemoteRequestFailure.notSent(.unsupported("Use Move to Trash / Restore from Trash for Gmail's Trash; Spam is not changed by mailin."))
            }
        }
        switch request {
        case .addLabel(let l), .removeLabel(let l): try label(l)
        case .move(let from, let to): try label(from); try label(to)
        case .moveToTrash(let from): try label(from)
        case .restoreFromTrash:
            // untrash restores the message's own labels; a destination is not chosen.
            return ResolvedChange(request: .restoreFromTrash(to: nil), precondition: precondition)
        default: break
        }
        return ResolvedChange(request: request, precondition: precondition)
    }

    public func state(of identity: ProviderMessageIdentity) async throws -> RemoteItemState {
        let id = try id(identity)
        let r = try await http.send("GET", try url(id, "?format=minimal"), mutating: false)
        guard let m = try? JSONDecoder().decode(Minimal.self, from: r.body) else {
            throw RemoteRequestFailure.refused("Gmail's answer could not be read")
        }
        if let returned = m.id, returned != id { throw RemoteRequestFailure.refused("Gmail answered with another message (\(returned))") }
        let labels = m.labelIds ?? []
        return RemoteItemState(exists: true, isRead: !labels.contains("UNREAD"), isFlagged: labels.contains("STARRED"),
                               folders: labels, inTrash: labels.contains("TRASH"), revision: m.historyId)
    }

    public func apply(_ change: ResolvedChange, to identity: ProviderMessageIdentity, before: RemoteItemState) async throws -> ProviderMessageIdentity? {
        let id = try id(identity)
        func modify(add: [String], remove: [String]) async throws {
            let body = RemoteActionHTTP.jsonBody(["addLabelIds": add, "removeLabelIds": remove])
            _ = try await http.send("POST", try url("\(id)/modify"), json: body, mutating: true)
        }
        switch change.request {
        case .markRead: try await modify(add: [], remove: ["UNREAD"])
        case .markUnread: try await modify(add: ["UNREAD"], remove: [])
        case .flag: try await modify(add: ["STARRED"], remove: [])
        case .unflag: try await modify(add: [], remove: ["STARRED"])
        case .addLabel(let l): try await modify(add: [l], remove: [])
        case .removeLabel(let l): try await modify(add: [], remove: [l])
        case .archiveOnServer: try await modify(add: [], remove: ["INBOX"])
        case .move(let from, let to): try await modify(add: [to], remove: [from])
        case .moveToTrash: _ = try await http.send("POST", try url("\(id)/trash"), mutating: true)
        case .restoreFromTrash: _ = try await http.send("POST", try url("\(id)/untrash"), mutating: true)
        }
        return nil          // a Gmail message id never changes
    }
}

// MARK: - Microsoft Graph

public actor GraphActionExecutor: RemoteActionExecutor {
    public nonisolated let accountID: UUID
    public nonisolated let provider: MailProviderKind = .microsoftGraph
    public nonisolated let mailbox: GraphMailbox
    let graphHost: String
    let apiVersion: String
    let http: RemoteActionHTTP
    private var folderIDs: [String: String] = [:]

    public init(accountID: UUID, mailbox: GraphMailbox = .me, tokens: any AccessTokenSource, transport: any SendHTTPTransport,
                permission: @escaping NetworkPermission, graphHost: String = GraphSignInSettings.defaultGraphHost,
                authorityHost: String = GraphSignInSettings.defaultAuthorityHost, apiVersion: String = "v1.0") {
        self.accountID = accountID; self.mailbox = mailbox
        let host = graphHost.lowercased()
        self.graphHost = host; self.apiVersion = apiVersion
        var core = RemoteActionHTTP(accountID: accountID, host: host, authorizationHost: authorityHost.lowercased(),
                                    audience: GraphAudience.resource(graphHost: host),
                                    changeScope: mailbox == .me ? ServerActionScopes.graphReadWrite : ServerActionScopes.graphReadWriteShared,
                                    tokens: tokens, transport: transport, permission: permission,
                                    scopeReasons: ["ErrorAccessDenied", "AccessDenied", "ErrorInsufficientPermissions"])
        // The same id before and after a move (§5.1): requested on every call.
        core.extraHeaders = ["Prefer": #"IdType="ImmutableId""#]
        core.tokenCheck = { try GraphOAuth.checkAudience(ofAccessToken: $0, graphHost: host) }
        http = core
    }

    struct MessageState: Decodable {
        struct Flag: Decodable { var flagStatus: String? }
        var id: String?
        var isRead: Bool?
        var flag: Flag?
        var parentFolderId: String?
        var changeKey: String?
    }
    struct FolderID: Decodable { var id: String }

    private func url(_ segments: [String], query: String = "") throws -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = graphHost
        c.percentEncodedPath = "/" + ([apiVersion] + mailbox.pathSegments + segments).map(GraphAdapter.escape).joined(separator: "/")
        if !query.isEmpty { c.percentEncodedQuery = query }
        guard let u = c.url else { throw RemoteRequestFailure.notSent(.unsupported("a Microsoft Graph address could not be built")) }
        return u
    }

    private func id(_ identity: ProviderMessageIdentity) throws -> String {
        guard case .graph(let box, let id) = identity, box == mailbox.identity else { throw RemoteRequestFailure.notSent(.accountMismatch) }
        return id
    }

    /// A well-known folder name (deleteditems, inbox, archive …) to the id
    /// Graph reports as `parentFolderId`; other values are ids already.
    func folderID(_ nameOrID: String) async throws -> String {
        let key = nameOrID.lowercased()
        guard GraphAdapter.wellKnownNames.contains(key) else { return nameOrID }
        if let known = folderIDs[key] { return known }
        let r: SendHTTPResponse
        do { r = try await http.send("GET", try url(["mailFolders", key], query: "$select=id"), mutating: false) } catch RemoteRequestFailure.gone {
            throw RemoteRequestFailure.refused("this mailbox has no \(key) folder")
        }
        guard let f = try? JSONDecoder().decode(FolderID.self, from: r.body), !f.id.isEmpty else {
            throw RemoteRequestFailure.refused("Microsoft Graph did not report the \(key) folder")
        }
        folderIDs[key] = f.id
        return f.id
    }

    public func resolve(_ request: RemoteChangeRequest, precondition: RemotePrecondition,
                        for identity: ProviderMessageIdentity) async throws -> ResolvedChange {
        _ = try id(identity)
        var p = precondition
        if let f = p.inFolder { p.inFolder = try await folderID(f) }
        switch request {
        case .addLabel, .removeLabel:
            throw RemoteRequestFailure.notSent(.unsupported("Outlook folders are changed with Move; labels are a Gmail feature."))
        case .archiveOnServer:
            throw RemoteRequestFailure.notSent(.unsupported("For Outlook, move the message to the Archive folder."))
        case .restoreFromTrash(nil):
            throw RemoteRequestFailure.notSent(.unsupported("Choose the folder to restore the message into."))
        case .move(let from, let to):
            return ResolvedChange(request: .move(from: try await folderID(from), to: try await folderID(to)), precondition: p)
        case .moveToTrash(let from):
            return ResolvedChange(request: .moveToTrash(from: try await folderID(from)), precondition: p)
        case .restoreFromTrash(let to?):
            return ResolvedChange(request: .restoreFromTrash(to: try await folderID(to)), precondition: p)
        default:
            return ResolvedChange(request: request, precondition: p)
        }
    }

    public func state(of identity: ProviderMessageIdentity) async throws -> RemoteItemState {
        let id = try id(identity)
        let trash = try await folderID("deleteditems")
        let r = try await http.send("GET", try url(["messages", id], query: "$select=id,isRead,flag,parentFolderId,changeKey"), mutating: false)
        guard let m = try? JSONDecoder().decode(MessageState.self, from: r.body) else {
            throw RemoteRequestFailure.refused("Microsoft Graph's answer could not be read")
        }
        let parent = m.parentFolderId ?? ""
        return RemoteItemState(exists: true, isRead: m.isRead, isFlagged: m.flag.map { $0.flagStatus == "flagged" },
                               folders: parent.isEmpty ? [] : [parent], inTrash: parent == trash, revision: m.changeKey)
    }

    public func apply(_ change: ResolvedChange, to identity: ProviderMessageIdentity, before: RemoteItemState) async throws -> ProviderMessageIdentity? {
        let id = try id(identity)
        func patch(_ body: [String: Any]) async throws {
            _ = try await http.send("PATCH", try url(["messages", id]), json: RemoteActionHTTP.jsonBody(body), mutating: true)
        }
        func move(_ destination: String) async throws -> ProviderMessageIdentity? {
            let r = try await http.send("POST", try url(["messages", id, "move"]),
                                        json: RemoteActionHTTP.jsonBody(["destinationId": destination]), mutating: true)
            // With immutable ids the moved message keeps its id; a different
            // id is recorded so the archive's identity can follow it.
            guard let moved = try? JSONDecoder().decode(MessageState.self, from: r.body), let newID = moved.id, newID != id else { return nil }
            return .graph(mailbox: mailbox.identity, immutableID: newID)
        }
        switch change.request {
        case .markRead: try await patch(["isRead": true])
        case .markUnread: try await patch(["isRead": false])
        case .flag: try await patch(["flag": ["flagStatus": "flagged"]])
        case .unflag: try await patch(["flag": ["flagStatus": "notFlagged"]])
        case .move(_, let to): return try await move(to)
        case .moveToTrash: return try await move(try await folderID("deleteditems"))
        case .restoreFromTrash(let to?): return try await move(to)
        case .restoreFromTrash(nil), .addLabel, .removeLabel, .archiveOnServer:
            throw RemoteRequestFailure.notSent(.unsupported("Not offered for Outlook accounts."))
        }
        return nil
    }
}

// MARK: - Transport without redirects

/// The app's transport for server actions: an ephemeral session that never
/// follows a redirect (the 3xx comes back and is refused), so a bearer token
/// never reaches another host.
public final class NoRedirectSendHTTPTransport: NSObject, SendHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(timeout: TimeInterval = 60) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func perform(_ request: SendHTTPRequest) async throws -> SendHTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpShouldHandleCookies = false
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        if !request.body.isEmpty { r.httpBody = request.body }
        do {
            let (data, response) = try await session.data(for: r)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)".lowercased()] = "\(v)" }
            return SendHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
        } catch let error as URLError where error.certainlyNotSent {
            throw NotSentError(error.localizedDescription)
        }
    }
}
