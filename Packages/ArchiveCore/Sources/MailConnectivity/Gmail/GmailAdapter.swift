//
//  GmailAdapter.swift
//  MailConnectivity
//
//  Plan v4 V4-05 (§3 A04/A06, §4 Gmail, §5.1–5.3): the Gmail API connector
//  behind the `MailProviderAdapter` contract. It replaces the old app path
//  (format=full, rawSource "", attachment ids never fetched, array results
//  with fetch caps) with:
//   • labels → folders; a message in several labels is ONE provider identity
//     (`.gmail(messageID:)`) with one membership per label — never extra
//     messages. "All Mail" (a pseudo-folder listed without a label filter)
//     captures messages that carry no label at all;
//   • state labels (UNREAD, STARRED, IMPORTANT) are provider flags, not folders;
//   • Spam and Trash are captured ONLY when the user selected them
//     (`GmailCaptureOptions`); a message moved there otherwise leaves the
//     selected scope (`.deleted` → "removed on server"; the preserved copy stays);
//   • enumeration = users.messages.list, every pageToken to the end;
//   • capture = users.messages.get?format=raw, base64url decoded chunk by
//     chunk straight into the staging file;
//   • change boundary = the profile historyId taken before the bootstrap;
//     changes = users.history.list, paged, (messagesAdded/Deleted,
//     labelsAdded/Removed); 404 / invalid start → `.changeTokenExpired`.
//  Every HTTP request asks the network policy first, carries the bearer
//  token for gmail.googleapis.com only, and never follows a redirect.
//

import ArchiveCore
import Foundation

public struct GmailCaptureOptions: Sendable, Equatable {
    /// Capture the Spam label (off unless the user selects it).
    public var includeSpam: Bool
    /// Capture the Trash label (off unless the user selects it).
    public var includeTrash: Bool
    /// messages.list page size (Gmail's maximum is 500) — a page, not a cap.
    public var pageSize: Int
    public var historyPageSize: Int
    public var maxConcurrentDownloads: Int

    public init(includeSpam: Bool = false, includeTrash: Bool = false, pageSize: Int = GmailAPI.maxPageSize,
                historyPageSize: Int = GmailAPI.maxPageSize, maxConcurrentDownloads: Int = 4) {
        self.includeSpam = includeSpam; self.includeTrash = includeTrash
        self.pageSize = min(max(1, pageSize), GmailAPI.maxPageSize)
        self.historyPageSize = min(max(1, historyPageSize), GmailAPI.maxPageSize)
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
    }
}

public enum GmailAdapterError: Error, LocalizedError, Equatable {
    /// The network policy refused a request; nothing was sent.
    case notPermitted(String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let why): return "Gmail was not contacted: \(why)"
        }
    }
}

public actor GmailAdapter: MailProviderAdapter {
    public nonisolated let accountID: UUID
    public nonisolated let provider: MailProviderKind = .gmail
    public nonisolated let mailHost: String = GmailAPI.host
    public nonisolated let authorizationHost: String? = GmailOAuth.tokenHost
    public nonisolated let tokenAudience: String? = GmailOAuth.audience
    public nonisolated let options: GmailCaptureOptions

    let transport: GmailHTTPTransport
    let permission: NetworkPermission

    private var labels: [String: GmailAPI.Label] = [:]
    private var labelsLoaded = false
    /// HTTP requests sent (diagnostics, tests).
    public private(set) var requestsSent = 0

    public init(accountID: UUID, transport: GmailHTTPTransport, permission: @escaping NetworkPermission,
                options: GmailCaptureOptions = GmailCaptureOptions()) {
        self.accountID = accountID; self.transport = transport; self.permission = permission; self.options = options
    }

    // MARK: Contract

    public func limits() async -> ProviderLimits {
        ProviderLimits(maxConcurrentDownloads: options.maxConcurrentDownloads, pageSize: options.pageSize,
                       changeTracking: .accountWide)
    }

    /// Every label in one response (labels.list is not paged), plus All Mail.
    /// Spam / Trash only when selected; state labels never.
    public func listFolders(pageToken: String?, context: ProviderRequestContext) async throws -> FolderPage {
        try await loadLabels(context: context)
        var folders = [allMail]
        let ordered = labels.values.sorted { a, b in
            let (ra, rb) = (Self.rank(a), Self.rank(b))
            return ra != rb ? ra < rb : (displayPath(a.id), a.id) < (displayPath(b.id), b.id)
        }
        for label in ordered where isFolder(label.id) { folders.append(occurrence(label.id)) }
        return FolderPage(folders: folders, nextPageToken: nil)
    }

    public func enumerate(folder: RemoteFolderOccurrence, cursor: String?, pageSize: Int,
                          context: ProviderRequestContext) async throws -> EnumerationPage {
        var query: [(String, String)] = [("maxResults", String(min(max(1, pageSize), GmailAPI.maxPageSize)))]
        let spamOrTrash = folder.serverID == "SPAM" || folder.serverID == "TRASH"
        if folder.serverID != GmailAPI.allMailID {
            guard GmailAPI.isSafeID(folder.serverID) else { throw MailProviderError.folderUnavailable(folder.serverID) }
            query.append(("labelIds", folder.serverID))
        }
        query.append(("includeSpamTrash", spamOrTrash ? "true" : "false"))
        if let cursor, !cursor.isEmpty { query.append(("pageToken", cursor)) }
        let list: GmailAPI.MessageList = try await json(GmailAPI.url("messages", query), call: .list(folder: folder.serverID),
                                                        context: context, operation: .request)
        var items: [RemoteItemRef] = []
        for ref in list.messages ?? [] {
            guard GmailAPI.isSafeID(ref.id) else { throw MailProviderError.permanent("Gmail listed a malformed message id.") }
            items.append(RemoteItemRef(identity: .gmail(messageID: ref.id), folder: folder))
        }
        let next = list.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        return EnumerationPage(items: items, nextCursor: next)
    }

    public func fetchRaw(_ item: RemoteItemRef, into sink: RawByteSink, context: ProviderRequestContext) async throws -> FetchedItemMetadata {
        guard case .gmail(let id) = item.identity else { throw MailProviderError.permanent("Not a Gmail message identity.") }
        guard GmailAPI.isSafeID(id) else { throw MailProviderError.permanent("Malformed Gmail message id.") }
        let response = try await send(GmailAPI.url("messages/\(id)", [("format", "raw")]), call: .message,
                                      context: context, operation: .download)
        var decoder = GmailRawStreamDecoder()
        do {
            for try await chunk in response.body {
                try decoder.feed(chunk) { try sink.write($0) }
            }
            try decoder.finish { try sink.write($0) }
        } catch let error as GmailRawDecodeError {
            switch error {
            case .truncated: throw MailProviderError.transient(error.localizedDescription)
            case .malformed, .missingRaw: throw MailProviderError.permanent(error.localizedDescription)
            }
        } catch {
            throw Self.transportError(error)
        }
        guard decoder.rawByteCount > 0 else { throw MailProviderError.permanent("Gmail returned an empty message.") }
        let meta: GmailAPI.RawMessageMeta
        do { meta = try JSONDecoder().decode(GmailAPI.RawMessageMeta.self, from: decoder.metadataJSON) } catch {
            throw MailProviderError.permanent("Gmail's message metadata could not be read.")
        }
        if let returned = meta.id, returned != id {
            throw MailProviderError.permanent("Gmail answered with another message (\(returned)).")
        }
        let labelIds = meta.labelIds ?? []
        try await ensureLabels(labelIds, context: context)
        var extra: [String: String] = [:]
        if let thread = meta.threadId { extra["gmailThreadId"] = thread }
        extra["gmailLabelIds"] = labelIds.joined(separator: ",")
        let internalDate = meta.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        let metadata = ProviderMetadata(representation: .gmailRaw, internalDate: internalDate, revision: meta.historyId,
                                        flags: labelIds.filter { GmailAPI.stateLabels.contains($0) }.sorted(), extra: extra)
        // Gmail states no exact byte size (sizeEstimate is an estimate);
        // completeness is the closed JSON object around a complete base64url value.
        return FetchedItemMetadata(occurrences: membership(labelIds).occurrences, metadata: metadata, expectedByteCount: nil)
    }

    /// The mailbox's own address as Gmail states it (users.getProfile
    /// `emailAddress`), so the account is named by the provider's answer and
    /// never only by what was typed. Nil when Gmail states none.
    public func profileAddress(context: ProviderRequestContext) async throws -> String? {
        let profile: GmailAPI.Profile = try await json(GmailAPI.url("profile"), call: .profile, context: context, operation: .request)
        let address = profile.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? nil : address
    }

    /// Ends the transport's session (the app drops or replaces this adapter).
    public func close() async { transport.invalidate() }

    public func changeBoundary(scope: ChangeScope, context: ProviderRequestContext) async throws -> String {
        guard case .account = scope else { throw MailProviderError.permanent("Gmail history is account-wide.") }
        let profile: GmailAPI.Profile = try await json(GmailAPI.url("profile"), call: .profile, context: context, operation: .request)
        guard let id = profile.historyId, Self.isHistoryID(id) else {
            throw MailProviderError.permanent("Gmail's profile carried no history id.")
        }
        return id
    }

    public func changes(scope: ChangeScope, since token: String, context: ProviderRequestContext) async throws -> ChangePage {
        guard case .account = scope else { throw MailProviderError.permanent("Gmail history is account-wide.") }
        let (start, pageToken) = try Self.parseResume(token)
        var query: [(String, String)] = [("startHistoryId", start), ("maxResults", String(options.historyPageSize))]
        for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] { query.append(("historyTypes", type)) }
        if let pageToken { query.append(("pageToken", pageToken)) }
        let list: GmailAPI.HistoryList = try await json(GmailAPI.url("history", query), call: .history,
                                                        context: context, operation: .request)
        let records = list.history ?? []
        var referenced: [String] = []
        for record in records {
            for event in (record.messagesAdded ?? []) + (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                referenced += event.message.labelIds ?? []
            }
        }
        try await ensureLabels(referenced, context: context)

        var changes: [RemoteChange] = []
        for record in records {
            // Within one record Gmail lists additions before label changes before deletions.
            for event in record.messagesAdded ?? [] {
                guard GmailAPI.isSafeID(event.message.id) else { continue }
                let scope = membership(event.message.labelIds ?? [])
                // A message that arrives straight into an unselected Spam / Trash is not in scope.
                if scope.inScope { changes.append(upsert(event.message.id, scope.occurrences, revision: record.id)) }
            }
            for event in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                guard GmailAPI.isSafeID(event.message.id), let current = event.message.labelIds else { continue }
                let scope = membership(current)
                changes.append(scope.inScope ? upsert(event.message.id, scope.occurrences, revision: record.id)
                                             : .deleted(.gmail(messageID: event.message.id)))
            }
            for event in record.messagesDeleted ?? [] where GmailAPI.isSafeID(event.message.id) {
                changes.append(.deleted(.gmail(messageID: event.message.id)))
            }
        }
        if let next = list.nextPageToken, !next.isEmpty {
            return ChangePage(changes: changes, resume: "\(start)|\(next)", hasMore: true)
        }
        // The last page: the mailbox's current history id is the new reconciliation point.
        let latest = list.historyId.flatMap { Self.isHistoryID($0) ? $0 : nil }
            ?? records.compactMap { $0.id.flatMap(UInt64.init) }.max().map(String.init) ?? start
        return ChangePage(changes: changes, resume: latest, hasMore: false)
    }

    // MARK: Labels and memberships

    private var allMail: RemoteFolderOccurrence {
        RemoteFolderOccurrence(serverID: GmailAPI.allMailID, displayPath: "All Mail", kind: .label, specialUse: "\\All")
    }

    private static func rank(_ label: GmailAPI.Label) -> Int {
        let order = ["INBOX", "SENT", "DRAFT", "CHAT", "SPAM", "TRASH"]
        if let i = order.firstIndex(of: label.id) { return i }
        return label.type == "system" ? order.count : order.count + 1
    }

    private func isFolder(_ id: String) -> Bool {
        if GmailAPI.stateLabels.contains(id) { return false }
        if id == "SPAM" { return options.includeSpam }
        if id == "TRASH" { return options.includeTrash }
        return true
    }

    private func displayPath(_ id: String) -> String {
        if let system = GmailAPI.systemNames[id] { return system }
        if let name = labels[id]?.name, !name.isEmpty { return name }
        return id
    }

    private func occurrence(_ id: String) -> RemoteFolderOccurrence {
        let system = labels[id]?.type == "system" || GmailAPI.systemNames[id] != nil
        return RemoteFolderOccurrence(serverID: id, displayPath: displayPath(id), kind: .label, specialUse: system ? id : nil)
    }

    /// A message's memberships from its labelIds: one occurrence per label
    /// (Inbox first), All Mail unless it is in Spam / Trash; state labels and
    /// unselected Spam / Trash dropped. `inScope` is false when the message
    /// sits in an unselected Spam or Trash.
    func membership(_ labelIds: [String]) -> (occurrences: [RemoteFolderOccurrence], inScope: Bool) {
        let inSpam = labelIds.contains("SPAM"), inTrash = labelIds.contains("TRASH")
        let inScope = (!inSpam || options.includeSpam) && (!inTrash || options.includeTrash)
        var seen = Set<String>()
        var ids = labelIds.filter { isFolder($0) && seen.insert($0).inserted }
        if let inbox = ids.firstIndex(of: "INBOX"), inbox != 0 { ids.insert(ids.remove(at: inbox), at: 0) }
        var occurrences = ids.map(occurrence)
        if !inSpam && !inTrash { occurrences.append(allMail) }
        return (occurrences, inScope)
    }

    private func upsert(_ id: String, _ occurrences: [RemoteFolderOccurrence], revision: String?) -> RemoteChange {
        .upserted(RemoteItemRef(identity: .gmail(messageID: id), folder: occurrences.first, changeToken: revision),
                  occurrences: occurrences)
    }

    private func loadLabels(context: ProviderRequestContext) async throws {
        let list: GmailAPI.LabelList = try await json(GmailAPI.url("labels"), call: .labels, context: context, operation: .request)
        var fresh: [String: GmailAPI.Label] = [:]
        for label in list.labels ?? [] where GmailAPI.isSafeID(label.id) { fresh[label.id] = label }
        labels = fresh
        labelsLoaded = true
    }

    /// A label created after the last folder list gets its real name (one
    /// labels.list, asked for like every request) rather than its bare id.
    private func ensureLabels(_ ids: [String], context: ProviderRequestContext) async throws {
        let unknown = ids.contains { labels[$0] == nil && GmailAPI.systemNames[$0] == nil && !GmailAPI.stateLabels.contains($0) }
        guard unknown || !labelsLoaded, !ids.isEmpty else { return }
        try await loadLabels(context: context)
    }

    // MARK: Resume tokens

    private static func isHistoryID(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 20 && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// "<startHistoryId>" or "<startHistoryId>|<pageToken>".
    static func parseResume(_ token: String) throws -> (String, String?) {
        let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let start = parts.first, isHistoryID(start) else { throw MailProviderError.changeTokenExpired }
        let page = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (start, page)
    }

    // MARK: HTTP

    private func ask(_ operation: SyncNetworkOperation) throws {
        do {
            try permission(NetworkAsk(accountID: accountID, host: mailHost, destination: .mailServer, operation: operation))
        } catch {
            throw GmailAdapterError.notPermitted(error.localizedDescription)
        }
    }

    /// One request: policy asked, bearer token for Gmail only, no redirect
    /// followed, non-2xx mapped. Returns the 2xx response with its body unread.
    private func send(_ url: URL, call: GmailAPI.Call, context: ProviderRequestContext,
                      operation: SyncNetworkOperation) async throws -> GmailHTTPResponse {
        guard url.scheme == "https", url.host?.lowercased() == mailHost else {
            throw MailProviderError.permanent("Refused to send the Gmail token to \(url.host ?? "an unknown host").")
        }
        guard let token = context.accessToken, !token.isEmpty else { throw MailProviderError.unauthorized }
        try Task.checkCancellation()
        try ask(context.attempt > 0 ? .retry : operation)
        requestsSent += 1
        let request = GmailHTTPRequest(url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"])
        let response: GmailHTTPResponse
        do { response = try await transport.send(request) } catch { throw Self.transportError(error) }
        if let answered = response.url?.host?.lowercased(), answered != mailHost {
            // A transport that followed a redirect: the answer is not used.
            throw MailProviderError.permanent("Gmail's answer came from another host (\(answered)) and was not used.")
        }
        if (300..<400).contains(response.status) {
            let target = response.headers["location"].flatMap { URL(string: $0)?.host } ?? "another address"
            throw MailProviderError.permanent("Gmail redirected the request to \(target); the redirect was not followed.")
        }
        guard (200..<300).contains(response.status) else {
            let body = try await Self.collect(response.body, limit: 64 * 1024)
            throw GmailAPI.error(status: response.status, headers: response.headers, body: body, call: call)
        }
        return response
    }

    private func json<T: Decodable>(_ url: URL, call: GmailAPI.Call, context: ProviderRequestContext,
                                    operation: SyncNetworkOperation) async throws -> T {
        let response = try await send(url, call: call, context: context, operation: operation)
        let body = try await Self.collect(response.body, limit: nil)
        do { return try JSONDecoder().decode(T.self, from: body) } catch {
            throw MailProviderError.permanent("Gmail's answer could not be read (\(T.self)).")
        }
    }

    /// Collects a small JSON body. `limit` bounds only an ERROR body's text.
    private static func collect(_ body: GmailByteStream, limit: Int?) async throws -> Data {
        var data = Data()
        do {
            for try await chunk in body {
                if let limit, data.count >= limit { continue }
                data.append(chunk)
            }
        } catch { throw transportError(error) }
        return data
    }

    static func transportError(_ error: Error) -> Error {
        if error is CancellationError || error is MailProviderError || error is GmailAdapterError { return error }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return MailProviderError.transient("The connection to Gmail failed (\(url.code.rawValue)).")
        }
        if Task.isCancelled { return CancellationError() }
        return error
    }
}
