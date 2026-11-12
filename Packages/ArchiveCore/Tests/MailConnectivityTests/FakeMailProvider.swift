//
//  FakeMailProvider.swift
//  MailConnectivityTests
//
//  V4-04: a deterministic, scriptable provider for the sync engine tests.
//  It is a small mail server in memory: folders (paged list), messages with
//  folder memberships, an account-wide change log with history ids, and
//  scripts that fire at exact points (after the n-th enumeration page, before
//  a fetch) to add, move or delete mail, expire history, or fail requests.
//  Connector authors can use it as the reference behaviour of the
//  `MailProviderAdapter` contract.
//

import Foundation
@testable import MailConnectivity
import ArchiveCore

/// Order of fetch starts across accounts (fairness).
actor FetchJournal {
    private(set) var starts: [UUID] = []
    func record(_ account: UUID) { starts.append(account) }
}

actor FakeMailProvider: MailProviderAdapter {
    nonisolated let accountID: UUID
    nonisolated let provider: MailProviderKind = .gmail
    nonisolated let mailHost = "gmail.googleapis.com"
    nonisolated let authorizationHost: String? = "oauth2.googleapis.com"
    nonisolated let tokenAudience: String?

    enum Action: Sendable {
        case add(String, folder: String)
        case move(String, to: [String])
        case delete(String)
        case expireHistory
        case run(@Sendable () async -> Void)
    }
    enum Trigger: Hashable, Sendable {
        /// After the n-th enumeration page (1-based, across folders) was built — listed, not yet downloaded.
        case afterEnumeratePage(Int)
        /// Before the fetch of this message id.
        case beforeFetch(String)
        /// Before the n-th fetch overall (1-based).
        case beforeFetchNumber(Int)
    }

    struct Message { var folders: [String]; let seq: Int; let body: Data }
    enum Event { case upsert(String, [String]), delete(String) }

    var tracking: ChangeTracking
    var pageSize: Int
    var folderPageSize = 20
    var changePageSize = 25
    var maxConcurrent = 4
    var fetchDelayNanoseconds: UInt64 = 0
    var chunkSize = 97
    /// When set, a request with any other access token is `.unauthorized`.
    var requiredToken: String?

    private(set) var folders: [RemoteFolderOccurrence] = []
    private(set) var messages: [String: Message] = [:]
    private var seq = 0
    private var history: [(id: Int, event: Event)] = []
    private var historyFloor = 0
    private var script: [Trigger: [Action]] = [:]
    private var fetchFailures: [String: [MailProviderError]] = [:]
    private var failEveryFetch: [String: MailProviderError] = [:]
    private var requestFailures: [MailProviderError] = []
    private let journal: FetchJournal?

    // Observations.
    private(set) var fetchCount = 0
    private(set) var fetched: [String] = []
    private(set) var enumeratePages = 0
    private(set) var maxItemsInOnePage = 0
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var requests = 0
    private(set) var tokensSeen: [String?] = []

    init(accountID: UUID = UUID(), tracking: ChangeTracking = .accountWide, pageSize: Int = 50,
         tokenAudience: String? = nil, journal: FetchJournal? = nil) {
        self.accountID = accountID; self.tracking = tracking; self.pageSize = pageSize
        self.tokenAudience = tokenAudience; self.journal = journal
    }

    // MARK: Setup

    static func body(_ id: String) -> Data {
        Data(("Message-ID: <\(id)@fake.example>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
              + "Subject: Message \(id) – ü\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
              + "Content-Type: text/plain; charset=utf-8\r\n\r\nBody \(id) end\r\n").utf8)
    }

    func addFolder(_ id: String, path: String? = nil) {
        folders.append(RemoteFolderOccurrence(serverID: id, displayPath: path ?? id, kind: .label))
    }

    /// Mailbox content present before the sync starts (also in the change log).
    func seed(_ id: String, folders: [String]) { apply(.add(id, folder: folders[0])); if folders.count > 1 { apply(.move(id, to: folders)) } }

    func on(_ trigger: Trigger, _ actions: [Action]) { script[trigger, default: []] += actions }
    func failFetch(_ id: String, with errors: [MailProviderError]) { fetchFailures[id] = errors }
    func failEveryFetch(of id: String, with error: MailProviderError?) { failEveryFetch[id] = error }
    func failNextRequests(_ errors: [MailProviderError]) { requestFailures = errors }
    func setRequiredToken(_ token: String?) { requiredToken = token }
    func setFetchDelay(_ ns: UInt64) { fetchDelayNanoseconds = ns }
    func setMaxConcurrent(_ n: Int) { maxConcurrent = n }

    var liveIDs: Set<String> { Set(messages.keys) }
    func membership(_ id: String) -> [String]? { messages[id]?.folders }

    // MARK: Mutations

    func apply(_ action: Action) {
        switch action {
        case .add(let id, let folder):
            seq += 1
            messages[id] = Message(folders: [folder], seq: seq, body: Self.body(id))
            history.append((seq, .upsert(id, [folder])))
        case .move(let id, let to):
            guard messages[id] != nil else { return }
            seq += 1
            messages[id]?.folders = to
            history.append((seq, .upsert(id, to)))
        case .delete(let id):
            guard messages.removeValue(forKey: id) != nil else { return }
            seq += 1
            history.append((seq, .delete(id)))
        case .expireHistory:
            historyFloor = seq + 1
        case .run:
            break
        }
    }

    private func fire(_ trigger: Trigger) async {
        guard let actions = script.removeValue(forKey: trigger) else { return }
        for action in actions {
            if case .run(let body) = action { await body() } else { apply(action) }
        }
    }

    private func checkRequest(_ context: ProviderRequestContext) throws {
        requests += 1
        tokensSeen.append(context.accessToken)
        if let requiredToken, context.accessToken != requiredToken { throw MailProviderError.unauthorized }
        if !requestFailures.isEmpty { throw requestFailures.removeFirst() }
    }

    private func occurrence(_ id: String) -> RemoteFolderOccurrence {
        folders.first { $0.serverID == id } ?? RemoteFolderOccurrence(serverID: id, displayPath: id, kind: .label)
    }

    // MARK: MailProviderAdapter

    func limits() async -> ProviderLimits {
        ProviderLimits(maxConcurrentDownloads: maxConcurrent, pageSize: pageSize, changeTracking: tracking)
    }

    func listFolders(pageToken: String?, context: ProviderRequestContext) async throws -> FolderPage {
        try checkRequest(context)
        let start = Int(pageToken ?? "0") ?? 0
        let end = min(folders.count, start + folderPageSize)
        return FolderPage(folders: Array(folders[start..<end]), nextPageToken: end < folders.count ? String(end) : nil)
    }

    func enumerate(folder: RemoteFolderOccurrence, cursor: String?, pageSize: Int,
                   context: ProviderRequestContext) async throws -> EnumerationPage {
        try checkRequest(context)
        guard folders.contains(where: { $0.serverID == folder.serverID }) else {
            throw MailProviderError.folderUnavailable(folder.serverID)
        }
        let after = Int(cursor ?? "0") ?? 0
        // Ordered by arrival; a bounded page (the engine never sees the whole folder at once).
        let inFolder = messages.filter { $0.value.folders.contains(folder.serverID) && $0.value.seq > after }
            .sorted { $0.value.seq < $1.value.seq }
        let page = inFolder.prefix(pageSize)
        let items = page.map { RemoteItemRef(identity: .gmail(messageID: $0.key), folder: folder,
                                             sizeHint: Int64($0.value.body.count)) }
        maxItemsInOnePage = max(maxItemsInOnePage, items.count)
        let next = inFolder.count > pageSize ? page.last.map { String($0.value.seq) } : nil
        enumeratePages += 1
        await fire(.afterEnumeratePage(enumeratePages))
        return EnumerationPage(items: items, nextCursor: next)
    }

    func fetchRaw(_ item: RemoteItemRef, into sink: RawByteSink, context: ProviderRequestContext) async throws -> FetchedItemMetadata {
        guard case .gmail(let id) = item.identity else { throw MailProviderError.permanent("not a fake identity") }
        fetchCount += 1
        await fire(.beforeFetchNumber(fetchCount))
        await fire(.beforeFetch(id))
        try checkRequest(context)
        await journal?.record(accountID)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if fetchDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: fetchDelayNanoseconds) }
        if var queue = fetchFailures[id], !queue.isEmpty {
            let error = queue.removeFirst()
            fetchFailures[id] = queue
            throw error
        }
        if let error = failEveryFetch[id] { throw error }
        guard let message = messages[id] else { throw MailProviderError.itemUnavailable }
        var offset = 0
        while offset < message.body.count {
            let end = min(message.body.count, offset + chunkSize)
            try sink.write(message.body.subdata(in: offset..<end))
            offset = end
        }
        fetched.append(id)
        return FetchedItemMetadata(occurrences: message.folders.map(occurrence),
                                   metadata: ProviderMetadata(representation: .gmailRaw, revision: String(message.seq)),
                                   expectedByteCount: Int64(message.body.count))
    }

    func changeBoundary(scope: ChangeScope, context: ProviderRequestContext) async throws -> String {
        try checkRequest(context)
        return String(seq)
    }

    func changes(scope: ChangeScope, since token: String, context: ProviderRequestContext) async throws -> ChangePage {
        try checkRequest(context)
        guard let start = Int(token), start + 1 >= historyFloor else { throw MailProviderError.changeTokenExpired }
        let pending = history.filter { $0.id > start }
        let page = pending.prefix(changePageSize)
        let changes: [RemoteChange] = page.map { entry in
            switch entry.event {
            case .upsert(let id, let to):
                let occ = to.map(occurrence)
                return .upserted(RemoteItemRef(identity: .gmail(messageID: id), folder: occ.first), occurrences: occ)
            case .delete(let id):
                return .deleted(.gmail(messageID: id))
            }
        }
        let resume = page.last.map { String($0.id) } ?? token
        return ChangePage(changes: changes, resume: resume, hasMore: pending.count > page.count)
    }
}
