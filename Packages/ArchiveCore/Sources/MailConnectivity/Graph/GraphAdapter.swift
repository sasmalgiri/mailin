//
//  GraphAdapter.swift
//  MailConnectivity
//
//  Plan v4 V4-06 (§3 A05/A06/A16, §4 Outlook / Microsoft 365, §5.1, §5.2):
//  the Microsoft Graph capture connector behind `MailProviderAdapter`.
//  It replaces the old Outlook pseudo-source path (headers + body without
//  MIME attachment parts, first `$top=50` folder page only, "inbox" read
//  from `/me/messages`).
//
//  What it does, request by request (every request asks the
//  `NetworkPermission` first, carries `Prefer: IdType="ImmutableId"`, and
//  goes only to the configured Graph host):
//   • Folder tree — the well-known folders are resolved by name first
//     (`/mailFolders/inbox` etc.: "Inbox" means the Inbox well-known folder,
//     whatever its display name, never `/me/messages`), then `mailFolders`
//     and every folder's `childFolders`, each followed through
//     `@odata.nextLink` to its end. Hidden folders only when asked for.
//   • Enumeration — `/mailFolders/{id}/messages` page by page
//     (`@odata.nextLink` is the cursor the engine persists).
//   • Changes — one delta per folder (`/mailFolders/{id}/messages/delta`).
//     The boundary is a delta link taken with `$deltatoken=latest`; each
//     page's nextLink (including EMPTY continuation pages) or final
//     deltaLink is the resume token. `@removed` entries are checked: a
//     message that still exists elsewhere (moved — its immutable ID did not
//     change) is reported in its new folder, only a 404 is a deletion.
//     410 / syncStateNotFound → `.changeTokenExpired` (full reconciliation).
//   • Capture — `/messages/{id}` metadata (parent folder, changeKey,
//     received time, flags), the attachment list when there is one
//     (file / item / reference kinds recorded; reference attachments are
//     links, recorded as references, never turned into invented bytes),
//     then `/messages/{id}/$value` streamed into the `RawByteSink`.
//     File and item attachments (attached .eml, inline images) come inside
//     that MIME. The MIME is recorded as `graph-mime`: a provider-produced
//     representation, not proof of the original SMTP / MAPI bytes (§5.2).
//   • Shared / delegated mailboxes — `/users/{id or UPN}/…` (needs
//     `Mail.Read.Shared`); a 403 is reported by name (`mailboxAccessDenied`).
//
//  Not reachable through Graph (stated, never implied): Exchange Online
//  IN-PLACE ARCHIVE mailboxes ("Online Archive"). The well-known `archive`
//  folder is the ordinary Archive folder of the primary mailbox.
//
//  Redirects: the transport never follows them. A same-host HTTPS redirect is
//  followed (bounded); a redirect — or a nextLink / deltaLink — naming any
//  other host is refused and that host never receives the bearer token.
//

import ArchiveCore
import Foundation

// MARK: - Configuration

public enum GraphMailbox: Sendable, Hashable {
    /// The signed-in user's own mailbox.
    case me
    /// A shared or delegated mailbox, by user id or UPN (needs `Mail.Read.Shared`).
    case user(String)

    /// The mailbox part of every message identity (§5.1).
    public var identity: String {
        switch self {
        case .me: return "me"
        case .user(let u): return u.lowercased()
        }
    }

    var pathSegments: [String] {
        switch self {
        case .me: return ["me"]
        case .user(let u): return ["users", u]
        }
    }
}

public struct GraphAdapterOptions: Sendable, Equatable {
    /// Hidden folders are listed only when the user asks for them.
    public var includeHiddenFolders: Bool
    /// Page size HINT (`$top` / `odata.maxpagesize`); never a mailbox limit.
    public var pageSize: Int
    /// Graph allows four concurrent requests per app per mailbox.
    public var maxConcurrentDownloads: Int
    public var graphHost: String
    public var authorityHost: String
    public var apiVersion: String

    public init(includeHiddenFolders: Bool = false, pageSize: Int = 100, maxConcurrentDownloads: Int = 4,
                graphHost: String = GraphSignInSettings.defaultGraphHost,
                authorityHost: String = GraphSignInSettings.defaultAuthorityHost, apiVersion: String = "v1.0") {
        self.includeHiddenFolders = includeHiddenFolders; self.pageSize = max(1, pageSize)
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.graphHost = graphHost.lowercased(); self.authorityHost = authorityHost.lowercased(); self.apiVersion = apiVersion
    }
}

// MARK: - Wire models

struct GraphCollection<T: Decodable>: Decodable {
    var value: [T]
    var nextLink: String?
    var deltaLink: String?
    enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink", deltaLink = "@odata.deltaLink" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent([T].self, forKey: .value) ?? []
        nextLink = try c.decodeIfPresent(String.self, forKey: .nextLink)
        deltaLink = try c.decodeIfPresent(String.self, forKey: .deltaLink)
    }
}

struct GraphFolder: Decodable {
    var id: String
    var displayName: String?
    var parentFolderId: String?
    var childFolderCount: Int?
}

struct GraphMessageRef: Decodable {
    struct Removed: Decodable { var reason: String? }
    var id: String
    var changeKey: String?
    var parentFolderId: String?
    var removed: Removed?
    enum CodingKeys: String, CodingKey { case id, changeKey, parentFolderId, removed = "@removed" }
}

struct GraphMessageMetadata: Decodable {
    struct Flag: Decodable { var flagStatus: String? }
    var id: String
    var parentFolderId: String?
    var changeKey: String?
    var receivedDateTime: String?
    var isRead: Bool?
    var hasAttachments: Bool?
    var categories: [String]?
    var internetMessageId: String?
    var flag: Flag?
}

struct GraphAttachment: Decodable {
    var odataType: String?
    var id: String?
    var name: String?
    var contentType: String?
    var size: Int64?
    var isInline: Bool?
    enum CodingKeys: String, CodingKey { case odataType = "@odata.type", id, name, contentType, size, isInline }

    var kind: String {
        switch odataType ?? "" {
        case "#microsoft.graph.fileAttachment": return "file"
        case "#microsoft.graph.itemAttachment": return "item"
        case "#microsoft.graph.referenceAttachment": return "reference"
        default: return odataType ?? "unknown"
        }
    }
}

struct GraphErrorBody: Decodable {
    struct Inner: Decodable { var code: String?; var message: String? }
    var error: Inner?
}

// MARK: - Adapter

public actor GraphAdapter: MailProviderAdapter {
    public nonisolated let accountID: UUID
    public nonisolated let provider: MailProviderKind = .microsoftGraph
    public nonisolated let mailHost: String
    public nonisolated let authorizationHost: String?
    public nonisolated let tokenAudience: String?
    public nonisolated let mailbox: GraphMailbox
    public nonisolated let options: GraphAdapterOptions

    /// Shown wherever an Outlook / Microsoft 365 capture's coverage is stated.
    public static let inPlaceArchiveNotice =
        "Microsoft Graph does not expose Exchange Online in-place archive mailboxes (Online Archive). "
        + "This capture covers the primary mailbox and any shared mailboxes you are allowed to read; "
        + "export the Online Archive separately to preserve it."
    /// Recorded with every Graph capture (§5.2).
    public static let mimeRepresentationNote =
        "MIME produced by Microsoft Graph (/messages/{id}/$value): a provider representation, "
        + "not proof of the original SMTP or MAPI bytes."

    /// Well-known folder names resolved before the tree walk. `msgfolderroot`
    /// is the tree root (not shown); `archive` is the ordinary Archive folder.
    static let wellKnownNames = ["msgfolderroot", "inbox", "sentitems", "drafts", "deleteditems", "junkemail", "archive", "outbox"]
    static let maxRedirects = 5
    static let messageSelect = "id,changeKey,parentFolderId"
    static let metadataSelect = "id,parentFolderId,changeKey,receivedDateTime,isRead,hasAttachments,categories,internetMessageId,flag"
    static let folderSelect = "id,displayName,parentFolderId,childFolderCount"

    let transport: GraphHTTPTransport
    let permission: NetworkPermission

    private var folderPaths: [String: String] = [:]
    private var specialUse: [String: String] = [:]
    private var rootID: String?

    /// HTTP requests sent (diagnostics, tests).
    public private(set) var requestsSent = 0

    public init(accountID: UUID, mailbox: GraphMailbox = .me, transport: GraphHTTPTransport,
                permission: @escaping NetworkPermission, options: GraphAdapterOptions = GraphAdapterOptions()) {
        self.accountID = accountID; self.mailbox = mailbox; self.transport = transport
        self.permission = permission; self.options = options
        self.mailHost = options.graphHost
        self.authorizationHost = options.authorityHost
        self.tokenAudience = GraphAudience.resource(graphHost: options.graphHost)
    }

    public func limits() async -> ProviderLimits {
        ProviderLimits(maxConcurrentDownloads: options.maxConcurrentDownloads, pageSize: options.pageSize, changeTracking: .perFolder)
    }

    /// The folder id Graph reports for a well-known name (after a folder listing).
    public func wellKnownFolderID(_ name: String) -> String? {
        specialUse.first { $0.value == name }?.key
    }

    // MARK: URLs

    /// One path segment: ids (base64url, may end in `=`), UPNs (`@`) and
    /// `$value` stay literal; `/`, `?`, `#`, `%`, spaces and the rest are escaped.
    static func escape(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~$@=+!*'(),;:")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// One query name or value: OData `$` names and `,` lists stay literal.
    static func escapeQuery(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~$,")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func url(_ segments: [String], query: [(String, String)] = []) throws -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = options.graphHost
        c.percentEncodedPath = "/" + ([options.apiVersion] + mailbox.pathSegments + segments).map(Self.escape).joined(separator: "/")
        if !query.isEmpty {
            c.percentEncodedQuery = query.map { "\(Self.escapeQuery($0.0))=\(Self.escapeQuery($0.1))" }.joined(separator: "&")
        }
        guard let url = c.url else { throw MailProviderError.permanent("a Microsoft Graph address could not be built") }
        return url
    }

    /// A nextLink / deltaLink / cursor handed back by the engine.
    func link(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw MailProviderError.permanent("graphInvalidLink: a stored Graph link is not a URL") }
        return url
    }

    // MARK: Requests

    private func ask(_ host: String, _ operation: SyncNetworkOperation) throws {
        do {
            try permission(NetworkAsk(accountID: accountID, host: host, destination: .mailServer, operation: operation))
        } catch {
            throw SyncEngine.Stop.notPermitted(error.localizedDescription)
        }
    }

    private func isGraphHost(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == options.graphHost && url.port == nil
    }

    /// One GET with the token, the immutable-ID preference, the policy check,
    /// and same-host redirects only.
    func get(_ start: URL, context: ProviderRequestContext, operation: SyncNetworkOperation = .request,
             maxPageSize: Int? = nil, accept: String = "application/json") async throws -> GraphHTTPResponse {
        guard isGraphHost(start) else {
            throw MailProviderError.permanent("graphForeignHost: a Graph link pointed at \(start.host ?? "another host"); the account's token is never sent there")
        }
        guard let token = context.accessToken, !token.isEmpty else { throw MailProviderError.unauthorized }
        do { try GraphOAuth.checkAudience(ofAccessToken: token, graphHost: options.graphHost) } catch {
            throw MailProviderError.permanent("tokenAudience: \(error.localizedDescription)")
        }
        var prefer = #"IdType="ImmutableId""#
        if let maxPageSize { prefer += ", odata.maxpagesize=\(maxPageSize)" }
        let headers = ["Authorization": "Bearer \(token)", "Prefer": prefer, "Accept": accept]
        var current = start
        for _ in 0...Self.maxRedirects {
            try Task.checkCancellation()
            try ask(options.graphHost, operation)
            requestsSent += 1
            let response: GraphHTTPResponse
            do {
                response = try await transport.send(GraphHTTPRequest(url: current, headers: headers))
            } catch let error as MailProviderError {
                throw error
            } catch let error as SyncEngine.Stop {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MailProviderError.transient(error.localizedDescription)
            }
            guard (300..<400).contains(response.status), response.status != 304 else { return response }
            guard let location = response.header("location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                throw MailProviderError.permanent("Microsoft Graph sent a redirect without a location")
            }
            guard isGraphHost(next) else {
                throw MailProviderError.permanent("graphRedirectRefused: Microsoft Graph redirected to \(next.host ?? "another host"); the account's token is never sent to another host")
            }
            current = next
        }
        throw MailProviderError.permanent("Microsoft Graph redirected more than \(Self.maxRedirects) times")
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: GraphHTTPResponse) async throws -> T {
        let data = try await response.collect()
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw MailProviderError.permanent("Microsoft Graph sent a response that could not be read (\(T.self))")
        }
    }

    static let expiredStateCodes: Set<String> = ["syncstatenotfound", "syncstateinvalid", "resyncrequired", "invalidsyncstate",
                                                 "errorinvalidsyncstatedata", "syncstateexpired"]

    /// Maps a non-2xx response onto the contract's errors.
    func failure(_ response: GraphHTTPResponse, notFound: MailProviderError) async -> MailProviderError {
        let body = (try? await response.collect(guardBytes: 1 << 20)) ?? Data()
        let error = (try? JSONDecoder().decode(GraphErrorBody.self, from: body))?.error
        let code = error?.code ?? ""
        let retryAfter = response.header("retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        if Self.expiredStateCodes.contains(code.lowercased()) { return .changeTokenExpired }
        switch response.status {
        case 401:
            return .unauthorized
        case 403:
            return .permanent("mailboxAccessDenied: the signed-in account may not read mailbox \(mailbox.identity) (HTTP 403\(code.isEmpty ? "" : ", \(code)")). The mailbox owner or an administrator must grant access.")
        case 404:
            return notFound
        case 410:
            return .changeTokenExpired
        case 429, 503:
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .transient("Microsoft Graph HTTP \(response.status)\(code.isEmpty ? "" : " \(code)")")
        default:
            return .permanent("Microsoft Graph HTTP \(response.status)\(code.isEmpty ? "" : " \(code)")\(error?.message.map { ": \($0)" } ?? "")")
        }
    }

    // MARK: Folders

    /// The folder walk's resumable state, carried in the page token.
    struct FolderWalk: Codable {
        struct Pending: Codable { var id: String?; var path: String? }
        var wellKnown: [String]
        var special: [String: String]
        var rootID: String?
        var next: String?
        var nextParentPath: String?
        var pending: [Pending]

        var finished: Bool { wellKnown.isEmpty && next == nil && pending.isEmpty }

        func encoded() throws -> String {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            return String(decoding: try e.encode(self), as: UTF8.self)
        }
        static func decode(_ s: String) throws -> FolderWalk {
            do { return try JSONDecoder().decode(FolderWalk.self, from: Data(s.utf8)) } catch {
                throw MailProviderError.permanent("graphInvalidFolderToken")
            }
        }
    }

    static func sanitize(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: "\u{2215}").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "(unnamed folder)" : n
    }

    func occurrence(_ id: String, path: String) -> RemoteFolderOccurrence {
        RemoteFolderOccurrence(serverID: id, displayPath: path, kind: .folder, specialUse: specialUse[id])
    }

    /// One request per call: a well-known name, or one page of a folder level.
    public func listFolders(pageToken: String?, context: ProviderRequestContext) async throws -> FolderPage {
        var walk = try pageToken.map(FolderWalk.decode) ?? FolderWalk(
            wellKnown: Self.wellKnownNames, special: [:], rootID: nil, next: nil, nextParentPath: nil,
            pending: [FolderWalk.Pending(id: nil, path: nil)])
        var out: [RemoteFolderOccurrence] = []

        if !walk.wellKnown.isEmpty {
            let name = walk.wellKnown.removeFirst()
            let response = try await get(try url(["mailFolders", name], query: [("$select", "id")]), context: context)
            if (200..<300).contains(response.status) {
                let folder = try await decode(GraphFolder.self, response)
                if name == "msgfolderroot" { walk.rootID = folder.id } else { walk.special[folder.id] = name }
            } else {
                // A mailbox without that well-known folder: nothing to map.
                let error = await failure(response, notFound: .itemUnavailable)
                if error != .itemUnavailable { throw error }
            }
        } else {
            let request: URL
            let parentPath: String?
            if let next = walk.next {
                request = try link(next)
                parentPath = walk.nextParentPath
            } else {
                let p = walk.pending.removeFirst()
                var query: [(String, String)] = [("$select", Self.folderSelect), ("$top", String(options.pageSize))]
                if options.includeHiddenFolders { query.append(("includeHiddenFolders", "true")) }
                request = try url(p.id.map { ["mailFolders", $0, "childFolders"] } ?? ["mailFolders"], query: query)
                parentPath = p.path
            }
            let response = try await get(request, context: context)
            if (200..<300).contains(response.status) {
                let page = try await decode(GraphCollection<GraphFolder>.self, response)
                for folder in page.value {
                    let name = Self.sanitize(folder.displayName ?? folder.id)
                    let path = parentPath.map { "\($0)/\(name)" } ?? name
                    if parentPath == nil, walk.rootID == nil { walk.rootID = folder.parentFolderId }
                    folderPaths[folder.id] = path
                    out.append(RemoteFolderOccurrence(serverID: folder.id, displayPath: path, kind: .folder,
                                                      specialUse: walk.special[folder.id]))
                    if (folder.childFolderCount ?? 0) > 0 { walk.pending.append(FolderWalk.Pending(id: folder.id, path: path)) }
                }
                walk.next = page.nextLink
                walk.nextParentPath = page.nextLink == nil ? nil : parentPath
            } else {
                // A folder deleted while its parent was being walked has no children to list.
                let error = await failure(response, notFound: .folderUnavailable("children"))
                guard case .folderUnavailable = error, parentPath != nil else { throw error }
                walk.next = nil; walk.nextParentPath = nil
            }
        }
        specialUse.merge(walk.special) { _, new in new }
        rootID = walk.rootID ?? rootID
        return FolderPage(folders: out, nextPageToken: walk.finished ? nil : try walk.encoded())
    }

    /// The occurrence of a folder id, resolving folders created after the
    /// last listing by walking up their parents (one request per level).
    func resolveOccurrence(_ id: String, context: ProviderRequestContext) async throws -> RemoteFolderOccurrence {
        if let path = folderPaths[id] { return occurrence(id, path: path) }
        var chain: [(String, String)] = []
        var cursor: String? = id
        var visited = Set<String>()
        var base: String?
        while let current = cursor, visited.insert(current).inserted {
            if let known = folderPaths[current] { base = known; break }
            if current == rootID { break }
            let response = try await get(try url(["mailFolders", current], query: [("$select", Self.folderSelect)]), context: context)
            guard (200..<300).contains(response.status) else {
                let error = await failure(response, notFound: .folderUnavailable(current))
                if case .folderUnavailable = error { break }
                throw error
            }
            let folder = try await decode(GraphFolder.self, response)
            chain.append((folder.id, Self.sanitize(folder.displayName ?? folder.id)))
            cursor = folder.parentFolderId
        }
        var path = base
        for (fid, name) in chain.reversed() {
            path = path.map { "\($0)/\(name)" } ?? name
            folderPaths[fid] = path
        }
        return occurrence(id, path: folderPaths[id] ?? id)
    }

    // MARK: Enumeration

    func identity(_ id: String) -> ProviderMessageIdentity { .graph(mailbox: mailbox.identity, immutableID: id) }

    public func enumerate(folder: RemoteFolderOccurrence, cursor: String?, pageSize: Int,
                          context: ProviderRequestContext) async throws -> EnumerationPage {
        let request = try cursor.map(link) ?? url(["mailFolders", folder.serverID, "messages"],
                                                  query: [("$select", Self.messageSelect), ("$top", String(max(1, pageSize)))])
        let response = try await get(request, context: context)
        guard (200..<300).contains(response.status) else {
            throw await failure(response, notFound: .folderUnavailable(folder.serverID))
        }
        let page = try await decode(GraphCollection<GraphMessageRef>.self, response)
        let items = page.value.map { RemoteItemRef(identity: identity($0.id), folder: folder, changeToken: $0.changeKey) }
        return EnumerationPage(items: items, nextCursor: page.nextLink)
    }

    // MARK: Capture

    public func fetchRaw(_ item: RemoteItemRef, into sink: RawByteSink, context: ProviderRequestContext) async throws -> FetchedItemMetadata {
        guard case .graph(let box, let id) = item.identity, box == mailbox.identity else {
            throw MailProviderError.permanent("not a message of Graph mailbox \(mailbox.identity)")
        }
        // 1. Metadata: where the message is now, its changeKey and flags.
        let metaResponse = try await get(try url(["messages", id], query: [("$select", Self.metadataSelect)]), context: context)
        guard (200..<300).contains(metaResponse.status) else { throw await failure(metaResponse, notFound: .itemUnavailable) }
        let meta = try await decode(GraphMessageMetadata.self, metaResponse)

        var extra: [String: String] = ["graphMailbox": mailbox.identity, "graphRepresentation": Self.mimeRepresentationNote]
        if let mid = meta.internetMessageId { extra["internetMessageId"] = mid }
        if let categories = meta.categories, !categories.isEmpty { extra["graphCategories"] = categories.joined(separator: "\u{1F}") }

        // 2. Attachment kinds. File and item attachments are inside the MIME;
        //    reference attachments are links and are recorded as such.
        if meta.hasAttachments == true {
            var attachments: [GraphAttachment] = []
            var next: URL? = try url(["messages", id, "attachments"], query: [("$select", "id,name,contentType,size,isInline")])
            while let request = next {
                let response = try await get(request, context: context)
                guard (200..<300).contains(response.status) else { throw await failure(response, notFound: .itemUnavailable) }
                let page = try await decode(GraphCollection<GraphAttachment>.self, response)
                attachments += page.value
                next = try page.nextLink.map(link)
            }
            func describe(_ a: GraphAttachment) -> [String: String] {
                var d = ["kind": a.kind, "name": a.name ?? ""]
                if let t = a.contentType { d["contentType"] = t }
                if let s = a.size { d["size"] = String(s) }
                if a.isInline == true { d["inline"] = "true" }
                return d
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            extra["graphAttachments"] = String(decoding: try encoder.encode(attachments.map(describe)), as: UTF8.self)
            let references = attachments.filter { $0.kind == "reference" }
            if !references.isEmpty {
                extra["graphReferenceAttachments"] = String(decoding: try encoder.encode(references.map(describe)), as: UTF8.self)
                extra["graphReferenceAttachmentNote"] = "Reference attachments are links to files stored elsewhere (OneDrive / SharePoint); their bytes are not part of the message and were not downloaded."
            }
        }

        // 3. The MIME, streamed exactly as received.
        let response = try await get(try url(["messages", id, "$value"]), context: context, operation: .download, accept: "*/*")
        guard (200..<300).contains(response.status) else { throw await failure(response, notFound: .itemUnavailable) }
        var iterator = response.body.makeAsyncIterator()
        while true {
            let chunk: Data?
            do { chunk = try await iterator.next() } catch let error as MailProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MailProviderError.transient("the message download was interrupted: \(error.localizedDescription)")
            }
            guard let chunk else { break }
            try sink.write(chunk)
        }

        var occurrences: [RemoteFolderOccurrence] = []
        if let parent = meta.parentFolderId { occurrences.append(try await resolveOccurrence(parent, context: context)) }
        var flags: [String] = []
        if meta.isRead == true { flags.append("isRead") }
        if meta.flag?.flagStatus == "flagged" { flags.append("flagged") }
        if meta.flag?.flagStatus == "complete" { flags.append("flagComplete") }
        let received = meta.receivedDateTime.flatMap { ISO8601DateFormatter().date(from: $0) }
        return FetchedItemMetadata(
            occurrences: occurrences,
            metadata: ProviderMetadata(representation: .graphMIME, internalDate: received, revision: meta.changeKey,
                                       flags: flags, extra: extra),
            expectedByteCount: response.header("content-length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) })
    }

    // MARK: Changes

    static let gonePrefix = "gone:"

    private func folder(of scope: ChangeScope) throws -> RemoteFolderOccurrence {
        guard case .folder(let f) = scope else {
            throw MailProviderError.permanent("Microsoft Graph tracks changes per folder, not per account")
        }
        return f
    }

    public func changeBoundary(scope: ChangeScope, context: ProviderRequestContext) async throws -> String {
        let f = try folder(of: scope)
        var request = try url(["mailFolders", f.serverID, "messages", "delta"],
                              query: [("$select", Self.messageSelect), ("$deltatoken", "latest")])
        while true {
            let response = try await get(request, context: context, maxPageSize: options.pageSize)
            guard (200..<300).contains(response.status) else {
                let error = await failure(response, notFound: .folderUnavailable(f.serverID))
                // Deleted since it was listed: nothing to track; its mail reappears where it went.
                if case .folderUnavailable = error { return Self.gonePrefix + f.serverID }
                throw error
            }
            let page = try await decode(GraphCollection<GraphMessageRef>.self, response)
            if let delta = page.deltaLink { return delta }
            // A service without `$deltatoken=latest` walks the initial round
            // to its end; the enumeration lists those messages.
            guard let next = page.nextLink else {
                throw MailProviderError.permanent("Microsoft Graph sent a delta page with neither a next nor a delta link")
            }
            request = try link(next)
        }
    }

    public func changes(scope: ChangeScope, since token: String, context: ProviderRequestContext) async throws -> ChangePage {
        let f = try folder(of: scope)
        if token.hasPrefix(Self.gonePrefix) { return ChangePage(changes: [], resume: token, hasMore: false) }
        let response = try await get(try link(token), context: context, maxPageSize: options.pageSize)
        guard (200..<300).contains(response.status) else {
            let error = await failure(response, notFound: .folderUnavailable(f.serverID))
            if case .folderUnavailable = error { return ChangePage(changes: [], resume: Self.gonePrefix + f.serverID, hasMore: false) }
            throw error
        }
        let page = try await decode(GraphCollection<GraphMessageRef>.self, response)
        var changes: [RemoteChange] = []
        for entry in page.value {
            if entry.removed != nil {
                // Removed from THIS folder: moved (same immutable id, now
                // elsewhere) or deleted. Only Graph knows which.
                let probe = try await get(try url(["messages", entry.id], query: [("$select", Self.messageSelect)]), context: context)
                if (200..<300).contains(probe.status) {
                    let now = try await decode(GraphMessageRef.self, probe)
                    if let parent = now.parentFolderId {
                        let occ = try await resolveOccurrence(parent, context: context)
                        changes.append(.upserted(RemoteItemRef(identity: identity(entry.id), folder: occ, changeToken: now.changeKey),
                                                 occurrences: [occ]))
                        continue
                    }
                    changes.append(.deleted(identity(entry.id)))
                } else {
                    let error = await failure(probe, notFound: .itemUnavailable)
                    guard error == .itemUnavailable else { throw error }
                    changes.append(.deleted(identity(entry.id)))
                }
            } else {
                let occ = try await resolveOccurrence(entry.parentFolderId ?? f.serverID, context: context)
                changes.append(.upserted(RemoteItemRef(identity: identity(entry.id), folder: occ, changeToken: entry.changeKey),
                                         occurrences: [occ]))
            }
        }
        if let next = page.nextLink { return ChangePage(changes: changes, resume: next, hasMore: true) }
        guard let delta = page.deltaLink else {
            throw MailProviderError.permanent("Microsoft Graph sent a delta page with neither a next nor a delta link")
        }
        return ChangePage(changes: changes, resume: delta, hasMore: false)
    }
}
