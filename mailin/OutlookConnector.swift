import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit
import os.log

private let outlookLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "OutlookConnector")

private final class OutlookOnceFlag: @unchecked Sendable {
    private var _done = false
    private let lock = NSLock()
    var done: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _done }
        set { lock.lock(); defer { lock.unlock() }; _done = newValue }
    }
}

// MARK: - OAuth Configuration

/// Register an app in Azure AD (Entra ID) and paste the Application (client) ID here.
/// Portal: https://entra.microsoft.com  ->  App registrations  ->  New registration
/// Set redirect URI to: msauth.com.ecosanskriti.mailin://auth
private let msClientID = "YOUR_AZURE_CLIENT_ID"
private let msTenantID = "common"
private let msRedirectURI = "msauth.com.ecosanskriti.mailin://auth"
private let msScopes = ["Mail.Read", "Mail.ReadBasic", "User.Read", "offline_access"]

private let msAuthorizeURL = "https://login.microsoftonline.com/\(msTenantID)/oauth2/v2.0/authorize"
private let msTokenURL = "https://login.microsoftonline.com/\(msTenantID)/oauth2/v2.0/token"
private let msGraphBase = "https://graph.microsoft.com/v1.0"

// MARK: - Keychain Keys

private enum OutlookKeys {
    static let accessToken = "outlookAccessToken"
    static let refreshToken = "outlookRefreshToken"
    static let tokenExpiry = "outlookTokenExpiry"
}

// MARK: - Models

struct OutlookFolder: Identifiable, Codable, Sendable {
    let id: String
    let displayName: String
    let totalItemCount: Int
    let unreadItemCount: Int
}

// MARK: - OutlookConnector

@MainActor
final class OutlookConnector: ObservableObject {
    static let shared = OutlookConnector()

    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var statusMessage = ""
    @Published var userDisplayName = ""

    private var accessToken: String = ""
    private var refreshToken: String = ""
    private var tokenExpiry: Date = .distantPast
    private var authSession: AnyObject?

    private init() {
        loadTokens()
    }

    // MARK: - Token Persistence

    private func loadTokens() {
        accessToken = KeychainHelper.load(key: OutlookKeys.accessToken)
        refreshToken = KeychainHelper.load(key: OutlookKeys.refreshToken)
        let expiryString = KeychainHelper.load(key: OutlookKeys.tokenExpiry)
        if let interval = TimeInterval(expiryString), interval > 0 {
            tokenExpiry = Date(timeIntervalSince1970: interval)
        }
        isAuthenticated = !refreshToken.isEmpty
        outlookLog.info("Loaded tokens — authenticated: \(self.isAuthenticated)")
    }

    private func saveTokens(access: String, refresh: String, expiresIn: Int) {
        accessToken = access
        refreshToken = refresh
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
        KeychainHelper.save(key: OutlookKeys.accessToken, value: access)
        KeychainHelper.save(key: OutlookKeys.refreshToken, value: refresh)
        KeychainHelper.save(key: OutlookKeys.tokenExpiry, value: String(tokenExpiry.timeIntervalSince1970))
        isAuthenticated = true
    }

    func signOut() {
        KeychainHelper.delete(key: OutlookKeys.accessToken)
        KeychainHelper.delete(key: OutlookKeys.refreshToken)
        KeychainHelper.delete(key: OutlookKeys.tokenExpiry)
        accessToken = ""
        refreshToken = ""
        tokenExpiry = .distantPast
        isAuthenticated = false
        userDisplayName = ""
        statusMessage = "Signed out"
        outlookLog.info("User signed out of Outlook")
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func computeCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - OAuth Authentication

    func authenticate() async throws {
        guard msClientID != "YOUR_AZURE_CLIENT_ID" else {
            throw OutlookError.invalidConfiguration("Outlook integration is not yet available. A future update will enable this feature.")
        }
        let verifier = generateCodeVerifier()
        let challenge = computeCodeChallenge(from: verifier)

        guard var components = URLComponents(string: msAuthorizeURL) else {
            throw OutlookError.invalidConfiguration("Invalid authorization URL")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: msClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: msRedirectURI),
            URLQueryItem(name: "scope", value: msScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query"),
        ]

        guard let authURL = components.url else {
            throw OutlookError.invalidConfiguration("Failed to build authorization URL")
        }

        outlookLog.info("Starting OAuth PKCE flow")
        statusMessage = "Opening Microsoft sign-in..."
        isLoading = true
        defer { isLoading = false }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let flag = OutlookOnceFlag()
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: msRedirectURI.components(separatedBy: "://").first
            ) { url, error in
                guard !flag.done else { return }
                flag.done = true
                if let error {
                    continuation.resume(throwing: OutlookError.authenticationFailed(error.localizedDescription))
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: OutlookError.authenticationFailed("No callback received"))
                }
            }
            self.authSession = session
            session.prefersEphemeralWebBrowserSession = false
            #if os(macOS)
            session.presentationContextProvider = NSAppPresentationContext.shared
            #endif
            session.start()
        }
        self.authSession = nil

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            if let errorDesc = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "error_description" })?.value {
                throw OutlookError.authenticationFailed(errorDesc)
            }
            throw OutlookError.authenticationFailed("No authorization code in callback")
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
        statusMessage = "Signed in to Outlook"
        outlookLog.info("OAuth flow completed successfully")
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        let body = [
            "client_id": msClientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": msRedirectURI,
            "code_verifier": verifier,
            "scope": msScopes.joined(separator: " "),
        ]
        let tokenResponse = try await postTokenRequest(body: body)
        let newRefresh = tokenResponse.refreshToken ?? refreshToken
        guard !newRefresh.isEmpty else {
            throw OutlookError.authenticationFailed("Server did not return a refresh token")
        }
        saveTokens(
            access: tokenResponse.accessToken,
            refresh: newRefresh,
            expiresIn: tokenResponse.expiresIn
        )
    }

    private func refreshAccessToken() async throws {
        guard !refreshToken.isEmpty else {
            throw OutlookError.notAuthenticated
        }
        outlookLog.info("Refreshing access token")
        let body = [
            "client_id": msClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": msScopes.joined(separator: " "),
        ]
        let tokenResponse = try await postTokenRequest(body: body)
        saveTokens(
            access: tokenResponse.accessToken,
            refresh: tokenResponse.refreshToken ?? refreshToken,
            expiresIn: tokenResponse.expiresIn
        )
    }

    private struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func postTokenRequest(body: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: msTokenURL) else {
            throw OutlookError.invalidConfiguration("Invalid token endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OutlookError.networkError("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            outlookLog.error("Token request failed (\(http.statusCode)): \(errorBody)")
            throw OutlookError.tokenExchangeFailed(http.statusCode, errorBody)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Authorized Requests

    private func validAccessToken() async throws -> String {
        if Date() >= tokenExpiry {
            try await refreshAccessToken()
        }
        guard !accessToken.isEmpty else { throw OutlookError.notAuthenticated }
        return accessToken
    }

    private func authorizedRequest(url: URL, retryCount: Int = 0) async throws -> (Data, HTTPURLResponse) {
        let token = try await validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OutlookError.networkError("Invalid response")
        }
        if http.statusCode == 401 && retryCount < 1 {
            try await refreshAccessToken()
            return try await authorizedRequest(url: url, retryCount: retryCount + 1)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OutlookError.apiError(http.statusCode, body)
        }
        return (data, http)
    }

    // MARK: - List Folders

    func listFolders() async throws -> [OutlookFolder] {
        guard let url = URL(string: "\(msGraphBase)/me/mailFolders?$top=50") else {
            throw OutlookError.invalidConfiguration("Bad mailFolders URL")
        }
        isLoading = true
        defer { isLoading = false }

        let (data, _) = try await authorizedRequest(url: url)
        let container = try JSONDecoder().decode(FolderListResponse.self, from: data)
        outlookLog.info("Fetched \(container.value.count) mail folders")
        return container.value.map {
            OutlookFolder(id: $0.id, displayName: $0.displayName,
                          totalItemCount: $0.totalItemCount ?? 0,
                          unreadItemCount: $0.unreadItemCount ?? 0)
        }
    }

    private struct FolderListResponse: Codable {
        let value: [GraphFolder]
    }

    private struct GraphFolder: Codable {
        let id: String
        let displayName: String
        let totalItemCount: Int?
        let unreadItemCount: Int?
    }

    // MARK: - Fetch Messages

    func fetchMessages(
        folder: String = "inbox",
        maxResults: Int = 200,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [MBOXParser.RawEmail] {
        isLoading = true
        defer { isLoading = false }
        statusMessage = "Fetching messages..."

        let selectFields = "$select=id,subject,from,toRecipients,ccRecipients,bccRecipients," +
            "receivedDateTime,sentDateTime,body,bodyPreview,hasAttachments," +
            "internetMessageId,conversationId,internetMessageHeaders,attachments"
        let expandFields = "$expand=attachments"
        let orderBy = "$orderby=receivedDateTime desc"

        let basePath: String
        if folder.lowercased() == "inbox" || folder.isEmpty {
            basePath = "\(msGraphBase)/me/messages"
        } else {
            basePath = "\(msGraphBase)/me/mailFolders/\(folder)/messages"
        }

        let batchSize = min(maxResults, 50)
        guard let firstURL = URL(string: "\(basePath)?\(selectFields)&\(expandFields)&\(orderBy)&$top=\(batchSize)") else {
            throw OutlookError.invalidConfiguration("Bad messages URL")
        }

        var allEmails: [MBOXParser.RawEmail] = []
        var nextURL: URL? = firstURL
        var fetched = 0

        while let pageURL = nextURL, fetched < maxResults {
            let (data, _) = try await authorizedRequest(url: pageURL)
            let page = try JSONDecoder().decode(MessageListResponse.self, from: data)

            for msg in page.value {
                if fetched >= maxResults { break }
                allEmails.append(convertToRawEmail(msg))
                fetched += 1
            }

            onProgress?(min(Double(fetched) / Double(maxResults), 1.0))
            outlookLog.info("Fetched \(fetched)/\(maxResults) messages")

            if let next = page.nextLink, fetched < maxResults {
                nextURL = URL(string: next)
            } else {
                nextURL = nil
            }
        }

        statusMessage = "Fetched \(allEmails.count) messages from Outlook"
        outlookLog.info("Fetch complete: \(allEmails.count) messages")
        return allEmails
    }

    // MARK: - Graph Response Models

    private struct MessageListResponse: Codable {
        let value: [GraphMessage]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct GraphMessage: Codable {
        let id: String
        let subject: String?
        let from: GraphEmailAddress?
        let toRecipients: [GraphEmailAddress]?
        let ccRecipients: [GraphEmailAddress]?
        let bccRecipients: [GraphEmailAddress]?
        let receivedDateTime: String?
        let sentDateTime: String?
        let body: GraphBody?
        let bodyPreview: String?
        let hasAttachments: Bool?
        let internetMessageId: String?
        let conversationId: String?
        let internetMessageHeaders: [GraphHeader]?
        let attachments: [GraphAttachment]?
    }

    private struct GraphEmailAddress: Codable {
        let emailAddress: EmailAddr?
        struct EmailAddr: Codable {
            let name: String?
            let address: String?
        }
    }

    private struct GraphBody: Codable {
        let contentType: String?
        let content: String?
    }

    private struct GraphHeader: Codable {
        let name: String?
        let value: String?
    }

    private struct GraphAttachment: Codable {
        let id: String?
        let name: String?
        let contentType: String?
        let size: Int?
        let contentBytes: String?
        let contentId: String?
        let isInline: Bool?
    }

    // MARK: - Conversion to RawEmail

    private func convertToRawEmail(_ msg: GraphMessage) -> MBOXParser.RawEmail {
        var headers: [String: String] = [:]

        let fromAddr = msg.from?.emailAddress
        let fromString = formatAddress(name: fromAddr?.name, address: fromAddr?.address)
        headers["From"] = fromString
        headers["To"] = formatRecipients(msg.toRecipients)
        headers["Cc"] = formatRecipients(msg.ccRecipients)
        headers["Bcc"] = formatRecipients(msg.bccRecipients)
        headers["Subject"] = msg.subject ?? "(No Subject)"
        headers["Date"] = msg.receivedDateTime ?? msg.sentDateTime ?? ""
        headers["Message-ID"] = msg.internetMessageId ?? "<\(msg.id)@graph.microsoft.com>"
        headers["X-MS-Conversation-ID"] = msg.conversationId

        if let extra = msg.internetMessageHeaders {
            for h in extra {
                if let name = h.name, let value = h.value, headers[name] == nil {
                    headers[name] = value
                }
            }
        }

        let isHTML = msg.body?.contentType?.lowercased() == "html"
        let bodyContent = msg.body?.content ?? ""
        let plainBody: String
        let htmlBody: String

        if isHTML {
            htmlBody = bodyContent
            plainBody = stripHTML(bodyContent)
        } else {
            plainBody = bodyContent
            htmlBody = ""
        }

        let timestamp = convertGraphDateToISO(msg.receivedDateTime ?? msg.sentDateTime)

        let rawSource = buildPseudoRawSource(headers: headers, plainBody: plainBody, htmlBody: htmlBody)

        let attachments: [AttachmentMetadata] = (msg.attachments ?? []).map { att in
            AttachmentMetadata(
                filename: att.name ?? "unnamed",
                mimeType: att.contentType ?? "application/octet-stream",
                size: att.size ?? 0,
                isInline: att.isInline ?? false,
                contentID: att.contentId,
                base64: att.contentBytes,
                fileURL: nil
            )
        }

        let domains = MBOXParser.extractDomains(from: headers)

        let threadID = msg.conversationId
            ?? msg.internetMessageId
            ?? MBOXParser.sha1("\(msg.subject ?? "")\(fromString)\(timestamp)")

        return MBOXParser.RawEmail(
            id: UUID(),
            headers: headers,
            rawSource: rawSource,
            messageType: "received",
            attachments: attachments,
            timestamp: timestamp,
            domains: domains,
            plainBody: plainBody,
            htmlBody: htmlBody,
            mimeRoot: nil,
            mimeSummary: nil,
            mimeDiagnostics: [],
            threadID: threadID,
            inReplyTo: headers["In-Reply-To"],
            references: headers["References"]?.split(separator: " ").map(String.init),
            tags: ["Outlook"],
            anomalies: []
        )
    }

    // MARK: - Formatting Helpers

    private func formatAddress(name: String?, address: String?) -> String {
        guard let addr = address, !addr.isEmpty else { return name ?? "" }
        if let name, !name.isEmpty {
            return "\(name) <\(addr)>"
        }
        return addr
    }

    private func formatRecipients(_ recipients: [GraphEmailAddress]?) -> String {
        guard let list = recipients, !list.isEmpty else { return "" }
        return list.map { formatAddress(name: $0.emailAddress?.name, address: $0.emailAddress?.address) }
            .joined(separator: ", ")
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convertGraphDateToISO(_ dateString: String?) -> String {
        guard let raw = dateString, !raw.isEmpty else { return "1970-01-01T00:00:00Z" }
        if raw.hasSuffix("Z") || raw.contains("+") || raw.contains("-", after: 10) {
            return raw
        }
        return raw + "Z"
    }

    private func buildPseudoRawSource(headers: [String: String], plainBody: String, htmlBody: String) -> String {
        var lines: [String] = []
        let orderedKeys = ["From", "To", "Cc", "Bcc", "Subject", "Date", "Message-ID"]
        for key in orderedKeys {
            if let val = headers[key], !val.isEmpty {
                lines.append("\(key): \(val)")
            }
        }
        for (key, val) in headers where !orderedKeys.contains(key) && !val.isEmpty {
            lines.append("\(key): \(val)")
        }
        lines.append("")
        lines.append(plainBody.isEmpty ? htmlBody : plainBody)
        return lines.joined(separator: "\r\n")
    }

    // MARK: - Errors

    enum OutlookError: LocalizedError {
        case invalidConfiguration(String)
        case authenticationFailed(String)
        case tokenExchangeFailed(Int, String)
        case notAuthenticated
        case networkError(String)
        case apiError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let msg): return "Configuration error: \(msg)"
            case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
            case .tokenExchangeFailed(let code, let msg): return "Token exchange failed (\(code)): \(msg)"
            case .notAuthenticated: return "Not signed in to Outlook. Please authenticate first."
            case .networkError(let msg): return "Network error: \(msg)"
            case .apiError(let code, let msg): return "Outlook API error (\(code)): \(msg)"
            }
        }
    }
}

// MARK: - String Extension

private extension String {
    func contains(_ char: Character, after index: Int) -> Bool {
        guard index < count else { return false }
        let start = self.index(startIndex, offsetBy: index)
        return self[start...].contains(char)
    }
}

// MARK: - macOS Presentation Context

#if os(macOS)
private class NSAppPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NSAppPresentationContext()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}
#endif
