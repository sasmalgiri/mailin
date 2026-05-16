#if !OFFLINE_MODE
import Foundation
import SwiftUI
import AuthenticationServices
import os.log
import CryptoKit

private let gmailLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "GmailConnector")

private final class GmailOnceFlag: @unchecked Sendable {
    private var _done = false
    private let lock = NSLock()
    var done: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _done }
        set { lock.lock(); defer { lock.unlock() }; _done = newValue }
    }
}

// MARK: - Configuration
// Replace with your OAuth client ID from https://console.cloud.google.com/apis/credentials
private let kGmailClientIDPlaceholder = "YOUR_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com"

struct GmailOAuthConfig {
    let clientID: String
    let redirectURI: String
    let scopes: [String]
    var scopeString: String { scopes.joined(separator: " ") }

    static let `default` = GmailOAuthConfig(
        clientID: kGmailClientIDPlaceholder,
        redirectURI: "com.ecosanskriti.mailincloud:/oauth2callback",
        scopes: ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.labels"]
    )
}

// MARK: - Gmail API Models

struct GmailLabel: Identifiable, Codable, Sendable {
    let id: String; let name: String; let type: String?; let messagesTotal: Int?; let messagesUnread: Int?
}
private struct GmailLabelList: Codable { let labels: [GmailLabel]? }
private struct GmailMessageList: Codable { let messages: [GmailMessageRef]?; let nextPageToken: String?; let resultSizeEstimate: Int? }
private struct GmailMessageRef: Codable { let id: String; let threadId: String? }
private struct GmailMessage: Codable {
    let id: String; let threadId: String?; let labelIds: [String]?; let snippet: String?
    let internalDate: String?; let payload: GmailPayload?; let sizeEstimate: Int?; let raw: String?
}
private struct GmailPayload: Codable {
    let mimeType: String?; let headers: [GmailHeader]?; let body: GmailBody?
    let parts: [GmailPayload]?; let filename: String?
}
private struct GmailHeader: Codable { let name: String; let value: String }
private struct GmailBody: Codable { let size: Int?; let data: String?; let attachmentId: String? }

private enum TokenKeys {
    static let access = "gmail_access_token"
    static let refresh = "gmail_refresh_token"
    static let expiry = "gmail_token_expiry"
}

// MARK: - Errors

enum GmailConnectorError: LocalizedError {
    case notAuthenticated, authenticationFailed(String), tokenRefreshFailed(String)
    case apiError(Int, String), invalidResponse, clientIDNotConfigured
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not authenticated. Please sign in to Gmail."
        case .authenticationFailed(let r): "Authentication failed: \(r)"
        case .tokenRefreshFailed(let r): "Token refresh failed: \(r)"
        case .apiError(let c, let m): "Gmail API error \(c): \(m)"
        case .invalidResponse: "Invalid response from Gmail API."
        case .clientIDNotConfigured: "Gmail integration is not yet available. A future update will enable this feature."
        }
    }
}

// MARK: - GmailConnector

@MainActor
class GmailConnector: ObservableObject {
    static let shared = GmailConnector()

    @Published var isAuthenticated = false
    @Published var userEmail = ""
    @Published var isFetching = false
    @Published var fetchProgress = 0.0
    @Published var statusMessage = ""

    private let config: GmailOAuthConfig
    private let session = URLSession.shared
    private var authSession: AnyObject?
    private let baseURL = "https://www.googleapis.com/gmail/v1/users/me"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    init(config: GmailOAuthConfig = .default) {
        self.config = config
        let access = KeychainHelper.load(key: TokenKeys.access)
        if !access.isEmpty {
            accessToken = access
            let refresh = KeychainHelper.load(key: TokenKeys.refresh)
            refreshToken = refresh.isEmpty ? nil : refresh
            if let t = TimeInterval(KeychainHelper.load(key: TokenKeys.expiry)) { tokenExpiry = Date(timeIntervalSince1970: t) }
            isAuthenticated = true
            gmailLog.info("Loaded stored Gmail tokens")
            Task { await fetchUserProfile() }
        }
    }

    private func storeTokens(access: String, refresh: String?, expiresIn: Int?) {
        accessToken = access
        KeychainHelper.save(key: TokenKeys.access, value: access)
        if let refresh { refreshToken = refresh; KeychainHelper.save(key: TokenKeys.refresh, value: refresh) }
        if let expiresIn {
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            tokenExpiry = expiry
            KeychainHelper.save(key: TokenKeys.expiry, value: String(expiry.timeIntervalSince1970))
        }
        isAuthenticated = true
    }

    func signOut() {
        accessToken = nil; refreshToken = nil; tokenExpiry = nil
        isAuthenticated = false; userEmail = ""
        [TokenKeys.access, TokenKeys.refresh, TokenKeys.expiry].forEach { KeychainHelper.delete(key: $0) }
        gmailLog.info("Signed out of Gmail")
    }

    // MARK: - OAuth 2.0 PKCE Authentication

    func authenticate() async throws {
        guard config.clientID != kGmailClientIDPlaceholder else { throw GmailConnectorError.clientIDNotConfigured }
        let verifier = generateCodeVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded

        guard var comp = URLComponents(string: authURL) else {
            throw GmailConnectorError.authenticationFailed("Invalid auth URL")
        }
        comp.queryItems = [
            .init(name: "client_id", value: config.clientID), .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: config.scopeString),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        guard let authorizationURL = comp.url else {
            throw GmailConnectorError.authenticationFailed("Bad authorization URL")
        }
        gmailLog.info("Starting OAuth PKCE flow")

        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let scheme = URL(string: config.redirectURI)?.scheme
            let flag = GmailOnceFlag()
            let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: scheme) { url, err in
                guard !flag.done else { return }
                flag.done = true
                if let err { cont.resume(throwing: GmailConnectorError.authenticationFailed(err.localizedDescription)) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: GmailConnectorError.authenticationFailed("No callback URL")) }
            }
            self.authSession = session
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = GmailAuthPresentationContext.shared
            session.start()
        }
        self.authSession = nil

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GmailConnectorError.authenticationFailed("No authorization code in callback")
        }

        let tokens = try await postTokenRequest(body: [
            "client_id": config.clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": config.redirectURI,
        ])
        storeTokens(access: tokens.accessToken, refresh: tokens.refreshToken, expiresIn: tokens.expiresIn)
        await fetchUserProfile()
        gmailLog.info("OAuth authentication completed")
    }

    private func fetchUserProfile() async {
        guard let url = URL(string: "\(baseURL)/profile") else { return }
        do {
            let (data, _) = try await authorizedRequest(url: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = json["emailAddress"] as? String {
                userEmail = email
            }
        } catch {
            gmailLog.warning("Failed to fetch user profile: \(error.localizedDescription)")
        }
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken else { throw GmailConnectorError.notAuthenticated }
        gmailLog.debug("Refreshing access token")
        do {
            let t = try await postTokenRequest(body: [
                "client_id": config.clientID, "refresh_token": refreshToken, "grant_type": "refresh_token",
            ])
            storeTokens(access: t.accessToken, refresh: t.refreshToken ?? refreshToken, expiresIn: t.expiresIn)
        } catch {
            gmailLog.error("Token refresh failed: \(error.localizedDescription)")
            throw GmailConnectorError.tokenRefreshFailed(error.localizedDescription)
        }
    }

    private struct TokenResponse: Codable {
        let accessToken: String; let refreshToken: String?; let expiresIn: Int?; let tokenType: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"; case refreshToken = "refresh_token"
            case expiresIn = "expires_in"; case tokenType = "token_type"
        }
    }

    private func postTokenRequest(body: [String: String]) async throws -> TokenResponse {
        guard let tokenURLParsed = URL(string: tokenURL) else {
            throw GmailConnectorError.authenticationFailed("Invalid token URL")
        }
        var req = URLRequest(url: tokenURLParsed)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GmailConnectorError.authenticationFailed(String(data: data, encoding: .utf8) ?? "Unknown")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    // MARK: - Authorized API Request
    private func authorizedRequest(url: URL) async throws -> (Data, HTTPURLResponse) {
        if let expiry = tokenExpiry, Date() >= expiry { try await refreshAccessToken() }
        guard let token = accessToken else { throw GmailConnectorError.notAuthenticated }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GmailConnectorError.invalidResponse }
        if http.statusCode == 401 {
            try await refreshAccessToken()
            guard let newToken = accessToken else { throw GmailConnectorError.notAuthenticated }
            req.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (d2, r2) = try await session.data(for: req)
            guard let h2 = r2 as? HTTPURLResponse else { throw GmailConnectorError.invalidResponse }
            guard (200...299).contains(h2.statusCode) else {
                throw GmailConnectorError.apiError(h2.statusCode, String(data: d2, encoding: .utf8) ?? "")
            }
            return (d2, h2)
        }
        guard (200...299).contains(http.statusCode) else {
            throw GmailConnectorError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    // MARK: - Public API
    func listLabels() async throws -> [GmailLabel] {
        guard let labelsURL = URL(string: "\(baseURL)/labels") else {
            throw GmailConnectorError.apiError(0, "Invalid labels URL")
        }
        let (data, _) = try await authorizedRequest(url: labelsURL)
        let result = try JSONDecoder().decode(GmailLabelList.self, from: data)
        gmailLog.info("Fetched \(result.labels?.count ?? 0) labels")
        return result.labels ?? []
    }

    func fetchMessages(maxResults: Int = 50, query: String? = nil,
                       onProgress: ((Double) -> Void)? = nil) async throws -> [MBOXParser.RawEmail] {
        isFetching = true; fetchProgress = 0; statusMessage = "Listing messages..."
        defer { isFetching = false; statusMessage = "" }
        let refs = try await listMessageIDs(maxResults: maxResults, query: query)
        guard !refs.isEmpty else { gmailLog.info("No messages found"); return [] }
        gmailLog.info("Fetching \(refs.count) messages")
        let total = Double(refs.count)
        let batchSize = 10
        var emails: [MBOXParser.RawEmail] = []
        emails.reserveCapacity(refs.count)
        for batchStart in stride(from: 0, to: refs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, refs.count)
            let batch = refs[batchStart..<batchEnd]
            let batchMessages = try await withThrowingTaskGroup(of: GmailMessage.self) { group in
                for ref in batch {
                    group.addTask { [self] in
                        try await self.fetchFullMessage(id: ref.id)
                    }
                }
                var results: [GmailMessage] = []
                for try await msg in group { results.append(msg) }
                return results
            }
            let batchResults = batchMessages.map { convertToRawEmail($0) }
            emails.append(contentsOf: batchResults)
            fetchProgress = Double(batchEnd) / total
            statusMessage = "Fetched \(batchEnd) of \(refs.count)..."
            onProgress?(fetchProgress)
        }
        gmailLog.info("Fetched and converted \(emails.count) emails")
        return emails
    }

    private func listMessageIDs(maxResults: Int, query: String?) async throws -> [GmailMessageRef] {
        var allRefs: [GmailMessageRef] = []; var pageToken: String?
        repeat {
            guard var comp = URLComponents(string: "\(baseURL)/messages") else {
                throw GmailConnectorError.apiError(0, "Invalid messages URL")
            }
            var items = [URLQueryItem(name: "maxResults", value: String(min(maxResults, 100)))]
            if let q = query, !q.isEmpty { items.append(.init(name: "q", value: q)) }
            if let pt = pageToken { items.append(.init(name: "pageToken", value: pt)) }
            comp.queryItems = items
            guard let messagesURL = comp.url else {
                throw GmailConnectorError.apiError(0, "Invalid messages URL with query items")
            }
            let (data, _) = try await authorizedRequest(url: messagesURL)
            let list = try JSONDecoder().decode(GmailMessageList.self, from: data)
            if let msgs = list.messages { allRefs.append(contentsOf: msgs) }
            pageToken = list.nextPageToken
            if allRefs.count >= maxResults { break }
        } while pageToken != nil
        return Array(allRefs.prefix(maxResults))
    }

    private func fetchFullMessage(id: String) async throws -> GmailMessage {
        guard var comp = URLComponents(string: "\(baseURL)/messages/\(id)") else {
            throw GmailConnectorError.apiError(0, "Invalid message URL for id: \(id)")
        }
        comp.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let url = comp.url else { throw GmailConnectorError.apiError(0, "Invalid message URL for id: \(id)") }
        let (data, _) = try await authorizedRequest(url: url)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    // MARK: - Gmail -> RawEmail Conversion
    private func convertToRawEmail(_ msg: GmailMessage) -> MBOXParser.RawEmail {
        var headers: [String: String] = [:]
        msg.payload?.headers?.forEach { headers[$0.name] = $0.value }
        let plain = extractBody(from: msg.payload, mime: "text/plain")
        let html = extractBody(from: msg.payload, mime: "text/html")
        let atts = extractAttachments(from: msg.payload)

        let timestamp: String
        if let ms = msg.internalDate.flatMap(TimeInterval.init) {
            timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
        } else {
            timestamp = MBOXParser.parseDate(headers["Date"]).map { ISO8601DateFormatter().string(from: $0) } ?? "1970-01-01T00:00:00Z"
        }
        let from = (headers["From"] ?? "").lowercased()
        let sender = userEmail.lowercased()

        return MBOXParser.RawEmail(
            id: UUID(), headers: headers,
            rawSource: "",
            messageType: !sender.isEmpty && from.contains(sender) ? "sent" : "received",
            attachments: atts, timestamp: timestamp,
            domains: MBOXParser.extractDomains(from: headers),
            plainBody: plain, htmlBody: html, mimeRoot: nil, mimeSummary: nil, mimeDiagnostics: [],
            threadID: msg.threadId ?? headers["Message-ID"] ?? UUID().uuidString,
            inReplyTo: headers["In-Reply-To"],
            references: headers["References"]?.split(separator: " ").map(String.init),
            tags: msg.labelIds ?? [], anomalies: []
        )
    }

    private func extractBody(from payload: GmailPayload?, mime: String) -> String {
        guard let payload else { return "" }
        if payload.mimeType == mime, let d = payload.body?.data { return d.base64URLDecoded ?? "" }
        for part in payload.parts ?? [] {
            let r = extractBody(from: part, mime: mime); if !r.isEmpty { return r }
        }
        return ""
    }

    private func extractAttachments(from payload: GmailPayload?) -> [AttachmentMetadata] {
        guard let payload else { return [] }
        var result: [AttachmentMetadata] = []
        if let fn = payload.filename, !fn.isEmpty, let body = payload.body, (body.attachmentId != nil || body.size ?? 0 > 0) {
            let cid = payload.headers?.first { $0.name == "Content-ID" }?.value
            result.append(AttachmentMetadata(filename: fn, mimeType: payload.mimeType ?? "application/octet-stream",
                                             size: body.size ?? 0, isInline: cid != nil, contentID: cid, base64: body.data, fileURL: nil))
        }
        for part in payload.parts ?? [] { result.append(contentsOf: extractAttachments(from: part)) }
        return result
    }
}

// MARK: - Auth Presentation Context
private class GmailAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GmailAuthPresentationContext()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}

// MARK: - Base64URL Helpers
private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
private extension String {
    var base64URLDecoded: String? {
        var b = replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if b.count % 4 != 0 { b.append(String(repeating: "=", count: 4 - b.count % 4)) }
        return Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
    }
}

#endif
