//
//  GmailAPI.swift
//  MailConnectivity
//
//  Plan v4 V4-05: the Gmail API v1 wire format the adapter uses (JSON shapes,
//  label vocabulary, error mapping). Endpoints, all under
//  https://gmail.googleapis.com/gmail/v1/users/me/ :
//    GET profile                          → historyId (the change boundary)
//    GET labels                           → every label (one response)
//    GET messages?labelIds=&pageToken=    → one enumeration page
//    GET messages/{id}?format=raw         → the complete RFC 822 bytes
//    GET history?startHistoryId=&pageToken=&historyTypes=…  → one change page
//

import ArchiveCore
import Foundation

public enum GmailAPI {
    public static let host = "gmail.googleapis.com"
    static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    /// Gmail's own maximum for messages.list / history.list.
    public static let maxPageSize = 500

    /// The pseudo-folder for every message outside Spam and Trash (Gmail's
    /// "All Mail"; listed with no label filter). It is how a message with
    /// no label at all (archived) is captured.
    public static let allMailID = "mailin:all-mail"

    /// Labels that are message STATE, not a place: kept as provider flags,
    /// never as archive folders.
    public static let stateLabels: Set<String> = ["UNREAD", "STARRED", "IMPORTANT"]

    static let systemNames: [String: String] = [
        "INBOX": "Inbox", "SENT": "Sent", "DRAFT": "Drafts", "SPAM": "Spam", "TRASH": "Trash", "CHAT": "Chats",
        "CATEGORY_PERSONAL": "Categories/Personal", "CATEGORY_SOCIAL": "Categories/Social",
        "CATEGORY_PROMOTIONS": "Categories/Promotions", "CATEGORY_UPDATES": "Categories/Updates",
        "CATEGORY_FORUMS": "Categories/Forums",
    ]

    static func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        // `+` means space to Google's query decoder: escape it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Gmail message / label ids are short ASCII tokens; anything else is
    /// refused rather than spliced into a URL.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
        }
    }

    // MARK: JSON shapes

    struct Profile: Decodable { var emailAddress: String?; var historyId: String? }

    struct Label: Decodable {
        var id: String
        var name: String?
        var type: String?
    }
    struct LabelList: Decodable { var labels: [Label]? }

    struct MessageRef: Decodable { var id: String; var threadId: String? }
    struct MessageList: Decodable {
        var messages: [MessageRef]?
        var nextPageToken: String?
    }

    /// `format=raw` metadata (the raw value is streamed separately).
    struct RawMessageMeta: Decodable {
        var id: String?
        var threadId: String?
        var labelIds: [String]?
        var historyId: String?
        var internalDate: String?
        var sizeEstimate: Int64?
    }

    struct HistoryMessage: Decodable { var id: String; var labelIds: [String]? }
    struct HistoryMessageEvent: Decodable { var message: HistoryMessage; var labelIds: [String]? }
    struct HistoryRecord: Decodable {
        var id: String?
        var messagesAdded: [HistoryMessageEvent]?
        var messagesDeleted: [HistoryMessageEvent]?
        var labelsAdded: [HistoryMessageEvent]?
        var labelsRemoved: [HistoryMessageEvent]?
    }
    struct HistoryList: Decodable {
        var history: [HistoryRecord]?
        var nextPageToken: String?
        var historyId: String?
    }

    struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { var reason: String?; var domain: String?; var message: String? }
        struct Body: Decodable { var code: Int?; var message: String?; var status: String?; var errors: [Detail]? }
        var error: Body?
    }

    // MARK: Errors

    /// Which call failed — a 404 means different things per call.
    enum Call { case profile, labels, list(folder: String), message, history }

    static let rateReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "concurrentLimitExceeded"]
    static let quotaReasons: Set<String> = ["dailyLimitExceeded", "quotaExceeded"]

    /// Maps a non-2xx Gmail response onto the engine's error vocabulary.
    static func error(status: Int, headers: [String: String], body: Data, call: Call,
                      now: Date = Date()) -> MailProviderError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        let reasons = Set((envelope?.error?.errors ?? []).compactMap(\.reason))
        let message = envelope?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let retryAfter = parseRetryAfter(headers["retry-after"], now: now)
        if !reasons.isDisjoint(with: quotaReasons) { return .quotaExceeded(resetAfter: retryAfter) }
        switch status {
        case 401:
            return .unauthorized
        case 403:
            if !reasons.isDisjoint(with: rateReasons) { return .rateLimited(retryAfter: retryAfter) }
            return .permanent("Gmail refused the request (HTTP 403\(reasons.isEmpty ? "" : ", " + reasons.sorted().joined(separator: ", "))): \(message)")
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 404, 410:
            switch call {
            case .message: return .itemUnavailable
            case .history: return .changeTokenExpired
            case .list(let folder): return .folderUnavailable(folder)
            case .profile, .labels: return .permanent("Gmail could not find the mailbox (HTTP \(status)).")
            }
        case 400:
            // A stale history page token / start id: a full reconciliation is safe.
            if case .history = call { return .changeTokenExpired }
            return .permanent("Gmail refused the request (HTTP 400): \(message)")
        case 503 where retryAfter != nil:
            return .rateLimited(retryAfter: retryAfter)
        case 500...599, 408:
            return .transient("Gmail answered HTTP \(status)")
        case 300...399:
            return .permanent("Gmail redirected the request (HTTP \(status)); the redirect was not followed.")
        default:
            return .permanent("Gmail refused the request (HTTP \(status)): \(message)")
        }
    }

    /// `Retry-After`: delta-seconds or an HTTP-date.
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}
