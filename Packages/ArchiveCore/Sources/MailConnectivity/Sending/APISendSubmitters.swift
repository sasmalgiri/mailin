//
//  APISendSubmitters.swift
//  MailConnectivity
//
//  Plan v4 V4-10 (§6): Gmail and Microsoft Graph send adapters over an
//  injected HTTP transport (the network-policy gate wraps the real one).
//
//   • Gmail: users.messages.send, media upload of the raw MIME
//     (`message/rfc822`, Gmail's documented limit 35 MB). 200 = accepted;
//     Gmail files the Sent copy itself (the response's SENT label confirms it).
//   • Graph: POST /me/sendMail with the MIME as base64 text (`text/plain`).
//     202 Accepted = accepted FOR PROCESSING, not delivered; Exchange files
//     the Sent copy itself. The request body is limited to 4 MB, so the
//     base64 overhead counts — a larger message is refused before sending,
//     with the limit stated.
//   • One request per submission; a 401 refreshes the token once (a 401 means
//     the provider did not take the message) and repeats the request once.
//   • A transport failure that may have reached the provider, or a 5xx, is
//     `.uncertain` — the outbox reconciles with the provider's Sent before
//     any resend. Only failures known to happen before any byte left are retried.
//

import Foundation

public struct SendHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data
    public init(method: String, url: URL, headers: [String: String], body: Data) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

public struct SendHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Lower-cased names.
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }); self.body = body
    }
}

/// Throw `NotSentError` when the request certainly never left the device.
public protocol SendHTTPTransport: Sendable {
    func perform(_ request: SendHTTPRequest) async throws -> SendHTTPResponse
}

public struct URLSessionSendHTTPTransport: SendHTTPTransport {
    let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }
    public func perform(_ request: SendHTTPRequest) async throws -> SendHTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
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

/// Shared by the Gmail and Graph submitters: token, permission, checkpoint,
/// one request, one refresh after a 401.
struct APISendCore: Sendable {
    let host: String
    let authorizationHost: String
    let audience: String
    let tokens: any AccessTokenSource
    let transport: any SendHTTPTransport
    let permission: NetworkPermission

    func run(_ message: OutboundMessage, checkpoint: SubmissionCheckpoint,
             request: (String) -> SendHTTPRequest, interpret: (SendHTTPResponse) -> SubmissionOutcome) async -> SubmissionOutcome {
        var token: String
        do { token = try await obtainToken(message.accountID, refresh: false) } catch { return tokenFailure(error) }
        do { try permission(NetworkAsk(accountID: message.accountID, host: host, destination: .mailServer, operation: .request)) } catch {
            return .retry(reason: "connecting to \(host) is not permitted: \(error.localizedDescription)", after: nil, quota: false, automatic: false)
        }
        if Task.isCancelled { return .retry(reason: "sending was stopped before it began", after: 0, quota: false, automatic: true) }
        do { try await checkpoint(.mayHaveReachedProvider) } catch {
            return .retry(reason: "the outbox could not record the send (\(error.localizedDescription)); nothing was sent", after: 0, quota: false, automatic: true)
        }
        var refreshed = false
        while true {
            let response: SendHTTPResponse
            do { response = try await transport.perform(request(token)) } catch let notSent as NotSentError {
                return .retry(reason: "could not reach \(host): \(notSent.reason)", after: nil, quota: false, automatic: true)
            } catch {
                return .uncertain(reason: "the connection to \(host) failed before its reply (\(error.localizedDescription))")
            }
            if response.status == 401 && !refreshed {
                refreshed = true
                do {
                    token = try await obtainToken(message.accountID, refresh: true)
                    try permission(NetworkAsk(accountID: message.accountID, host: host, destination: .mailServer, operation: .retry))
                } catch { return tokenFailure(error) }
                continue
            }
            if response.status == 401 { return .needsSignIn(reason: "\(host) did not accept the sign-in") }
            return interpret(response)
        }
    }

    private func obtainToken(_ account: UUID, refresh: Bool) async throws -> String {
        try permission(NetworkAsk(accountID: account, host: authorizationHost, destination: .authorization, operation: .oauthRefresh))
        return refresh ? try await tokens.refreshAfterRejection(account: account, audience: audience)
                       : try await tokens.accessToken(for: account, audience: audience)
    }

    private func tokenFailure(_ error: Error) -> SubmissionOutcome {
        if case OAuthError.reauthorisationNeeded = error { return .needsSignIn(reason: "this account needs you to sign in again") }
        return .retry(reason: "a sign-in token could not be obtained: \(error.localizedDescription)", after: nil, quota: false, automatic: true)
    }

    static func retryAfter(_ r: SendHTTPResponse) -> TimeInterval? {
        guard let v = r.headers["retry-after"]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let s = TimeInterval(v) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: v).map { max(0, $0.timeIntervalSinceNow) }
    }
}

// MARK: - Gmail

public struct GmailSendSubmitter: MessageSubmitter {
    /// Gmail's documented maximum for a message sent through the API.
    public static let maximumMessageBytes = 35 * 1024 * 1024
    public static let endpoint = URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=media")!
    let core: APISendCore

    public init(tokens: any AccessTokenSource, transport: any SendHTTPTransport, permission: @escaping NetworkPermission,
                audience: String = "https://gmail.googleapis.com", authorizationHost: String = "oauth2.googleapis.com") {
        core = APISendCore(host: "gmail.googleapis.com", authorizationHost: authorizationHost, audience: audience,
                           tokens: tokens, transport: transport, permission: permission)
    }

    struct Sent: Decodable { var id: String?; var labelIds: [String]? }
    struct ErrorBody: Decodable {
        struct Inner: Decodable { struct Reason: Decodable { var reason: String? }; var message: String?; var errors: [Reason]?; var status: String? }
        var error: Inner?
    }

    public func submit(_ message: OutboundMessage, checkpoint: @escaping SubmissionCheckpoint) async -> SubmissionOutcome {
        guard message.bytes.count <= Self.maximumMessageBytes else {
            return .rejected(reason: "the message (\(message.bytes.count) bytes) is larger than Gmail's limit of 35 MB", rejectedRecipients: [])
        }
        return await core.run(message, checkpoint: checkpoint, request: { token in
            SendHTTPRequest(method: "POST", url: Self.endpoint,
                            headers: ["Authorization": "Bearer \(token)", "Content-Type": "message/rfc822"], body: message.bytes)
        }, interpret: Self.interpret)
    }

    static func interpret(_ r: SendHTTPResponse) -> SubmissionOutcome {
        if (200..<300).contains(r.status) {
            let sent = try? JSONDecoder().decode(Sent.self, from: r.body)
            return .accepted(response: "Gmail accepted the message" + (sent?.id.map { " (id \($0))" } ?? ""),
                             providerReference: sent?.id, savedToSent: sent?.labelIds?.contains("SENT") == true)
        }
        let err = (try? JSONDecoder().decode(ErrorBody.self, from: r.body))?.error
        let reasons = Set((err?.errors ?? []).compactMap(\.reason))
        let detail = "HTTP \(r.status)" + (err?.message.map { ": \($0)" } ?? "")
        let quotaReasons: Set<String> = ["dailyLimitExceeded", "userRateLimitExceeded", "rateLimitExceeded", "quotaExceeded", "dailyLimitExceededUnreg"]
        if r.status == 429 || !reasons.isDisjoint(with: quotaReasons) {
            return .retry(reason: "Gmail's sending limit was reached (\(detail))", after: APISendCore.retryAfter(r) ?? 3600, quota: true, automatic: true)
        }
        if r.status == 403 { return .needsSignIn(reason: "Gmail did not allow mailin to send from this account (\(detail))") }
        if (400..<500).contains(r.status) { return .rejected(reason: "Gmail refused the message (\(detail))", rejectedRecipients: []) }
        return .uncertain(reason: "Gmail answered \(detail) — the message may or may not have been sent")
    }
}

// MARK: - Microsoft Graph

public struct GraphSendSubmitter: MessageSubmitter {
    /// Graph's per-request body limit; the base64 MIME must fit.
    public static let maximumRequestBytes = 4 * 1024 * 1024
    public static let endpoint = URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!
    let core: APISendCore

    public init(tokens: any AccessTokenSource, transport: any SendHTTPTransport, permission: @escaping NetworkPermission,
                audience: String = "https://graph.microsoft.com", authorizationHost: String = "login.microsoftonline.com") {
        core = APISendCore(host: "graph.microsoft.com", authorizationHost: authorizationHost, audience: audience,
                           tokens: tokens, transport: transport, permission: permission)
    }

    struct ErrorBody: Decodable { struct Inner: Decodable { var code: String?; var message: String? }; var error: Inner? }

    public func submit(_ message: OutboundMessage, checkpoint: @escaping SubmissionCheckpoint) async -> SubmissionOutcome {
        let body = message.bytes.base64EncodedData()
        guard body.count <= Self.maximumRequestBytes else {
            return .rejected(reason: "the message is \(message.bytes.count) bytes (\(body.count) once encoded); Microsoft's send limit for one request is 4 MB encoded",
                             rejectedRecipients: [])
        }
        return await core.run(message, checkpoint: checkpoint, request: { token in
            SendHTTPRequest(method: "POST", url: Self.endpoint,
                            headers: ["Authorization": "Bearer \(token)", "Content-Type": "text/plain"], body: body)
        }, interpret: Self.interpret)
    }

    static func interpret(_ r: SendHTTPResponse) -> SubmissionOutcome {
        if r.status == 202 || r.status == 200 {
            return .accepted(response: "Microsoft accepted the message for processing (HTTP \(r.status); not a delivery confirmation)",
                             providerReference: r.headers["request-id"], savedToSent: false)
        }
        let err = (try? JSONDecoder().decode(ErrorBody.self, from: r.body))?.error
        let code = err?.code ?? ""
        let detail = "HTTP \(r.status)" + (code.isEmpty ? "" : " \(code)") + (err?.message.map { ": \($0)" } ?? "")
        let quotaCodes: Set<String> = ["ErrorSubmissionQuotaExceeded", "ErrorExceededMessageLimit", "ErrorMessageSubmissionBlocked"]
        if r.status == 429 || quotaCodes.contains(code) {
            return .retry(reason: "Microsoft's sending limit was reached (\(detail))", after: APISendCore.retryAfter(r) ?? (r.status == 429 ? 60 : 3600),
                          quota: true, automatic: true)
        }
        if r.status == 403 && code != "ErrorSendAsDenied" {
            return .needsSignIn(reason: "Microsoft did not allow mailin to send from this account (\(detail))")
        }
        if (400..<500).contains(r.status) { return .rejected(reason: "Microsoft refused the message (\(detail))", rejectedRecipients: []) }
        return .uncertain(reason: "Microsoft answered \(detail) — the message may or may not have been sent")
    }
}
