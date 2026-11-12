//
//  GraphSimulator.swift
//  MailConnectivityTests
//
//  V4-06: a deterministic Microsoft Graph mail service in memory, behind the
//  `GraphHTTPTransport` seam (no network). It models what the connector
//  depends on:
//   • mailboxes (`/me`, `/users/{upn}`), with per-mailbox access (403 when the
//     signed-in user may not read a shared mailbox);
//   • a folder tree with well-known names, hidden folders, `childFolders`,
//     `$top`/`$skip` paging with `@odata.nextLink`;
//   • messages whose ids are IMMUTABLE only when the request carries
//     `Prefer: IdType="ImmutableId"` — otherwise the id changes on every move
//     (as Exchange's default ids do), so an adapter that forgets the header
//     duplicates a moved message;
//   • per-folder delta: `$deltatoken=latest`, nextLink/deltaLink pages,
//     optional EMPTY continuation pages, `@removed` for moved-out / deleted
//     messages, expiry (410 SyncStateNotFound);
//   • `/messages/{id}`, `/attachments` (file / item / reference) and
//     `/$value` streamed in small chunks with Content-Length;
//   • scripted failures and redirects; every request recorded.
//

import Foundation
@testable import MailConnectivity

actor GraphSimulator: GraphHTTPTransport {
    static let host = "graph.microsoft.com"

    struct Folder { var id: String; var name: String; var parent: String; var hidden: Bool }
    struct Attachment { var type: String; var name: String; var contentType: String; var size: Int; var isInline: Bool }
    struct Message {
        var id: String; var folder: String; var mime: Data; var changeKey = 1; var moves = 0
        var created: Int; var attachments: [Attachment] = []; var isRead = false
    }
    struct Mailbox {
        var upn: String
        var folders: [String: Folder] = [:]
        var folderOrder: [String] = []
        var wellKnown: [String: String] = [:]
        var messages: [String: Message] = [:]
        var log: [(seq: Int, folder: String, id: String)] = []
        var rootID: String
    }
    struct Failure { var pathContains: String; var status: Int; var code: String?; var headers: [String: String]; var times: Int }

    private(set) var mailboxes: [String: Mailbox] = [:]
    let primary: String
    var denied: Set<String> = []
    private var seq = 0
    private var created = 0
    private var epoch = 0
    var folderPageSize = 10
    var chunkSize = 97
    var supportsLatestDeltaToken = true
    /// Empty pages (with a nextLink) served before the real content of the
    /// next delta round that is requested.
    var emptyContinuationPages = 0
    var acceptedToken: String?
    private var failures: [Failure] = []
    private var redirects: [(pathContains: String, location: String)] = []

    // Observations.
    private(set) var requests: [GraphHTTPRequest] = []
    private(set) var foreignRequests: [GraphHTTPRequest] = []
    private(set) var valueDownloads: [String: Int] = [:]
    private(set) var emptyPagesServed = 0
    private(set) var collectionRequests = 0

    init(primary: String = "asha@contoso.com") {
        self.primary = primary
        let key = primary.lowercased()
        var box = Mailbox(upn: key, rootID: "root-\(key)")
        box.wellKnown["msgfolderroot"] = box.rootID
        mailboxes[key] = box
    }

    // MARK: Setup

    func addMailbox(_ upn: String) {
        let key = upn.lowercased()
        var box = Mailbox(upn: key, rootID: "root-\(key)")
        box.wellKnown["msgfolderroot"] = box.rootID
        mailboxes[key] = box
    }

    func deny(_ upn: String) { denied.insert(upn.lowercased()) }
    func setFolderPageSize(_ n: Int) { folderPageSize = n }
    func setEmptyContinuationPages(_ n: Int) { emptyContinuationPages = n }
    func setSupportsLatest(_ v: Bool) { supportsLatestDeltaToken = v }
    func setAcceptedToken(_ t: String?) { acceptedToken = t }

    @discardableResult
    func addFolder(_ id: String, name: String, parent: String? = nil, hidden: Bool = false, wellKnown: String? = nil,
                   mailbox: String? = nil) -> String {
        let key = (mailbox ?? primary).lowercased()
        let root = mailboxes[key]!.rootID
        mailboxes[key]!.folders[id] = Folder(id: id, name: name, parent: parent ?? root, hidden: hidden)
        mailboxes[key]!.folderOrder.append(id)
        if let wellKnown { mailboxes[key]!.wellKnown[wellKnown] = id }
        return id
    }

    func deleteFolder(_ id: String, mailbox: String? = nil) {
        let key = (mailbox ?? primary).lowercased()
        mailboxes[key]!.folders[id] = nil
        mailboxes[key]!.folderOrder.removeAll { $0 == id }
    }

    func addMessage(_ id: String, folder: String, mime: Data? = nil, attachments: [Attachment] = [], mailbox: String? = nil) {
        let key = (mailbox ?? primary).lowercased()
        seq += 1; created += 1
        mailboxes[key]!.messages[id] = Message(id: id, folder: folder, mime: mime ?? Self.mime(id), created: created,
                                              attachments: attachments)
        mailboxes[key]!.log.append((seq, folder, id))
    }

    func move(_ id: String, to folder: String, mailbox: String? = nil) {
        let key = (mailbox ?? primary).lowercased()
        guard let from = mailboxes[key]!.messages[id]?.folder else { return }
        seq += 1
        mailboxes[key]!.messages[id]!.folder = folder
        mailboxes[key]!.messages[id]!.moves += 1
        mailboxes[key]!.messages[id]!.changeKey += 1
        mailboxes[key]!.log.append((seq, from, id))
        mailboxes[key]!.log.append((seq, folder, id))
    }

    func delete(_ id: String, mailbox: String? = nil) {
        let key = (mailbox ?? primary).lowercased()
        guard let m = mailboxes[key]!.messages.removeValue(forKey: id) else { return }
        seq += 1
        mailboxes[key]!.log.append((seq, m.folder, id))
    }

    /// Every delta token issued so far becomes invalid (410 SyncStateNotFound).
    func expireDeltaTokens() { epoch += 1 }

    func fail(_ pathContains: String, status: Int, code: String? = nil, headers: [String: String] = [:], times: Int = 1) {
        failures.append(Failure(pathContains: pathContains, status: status, code: code, headers: headers, times: times))
    }

    func redirect(_ pathContains: String, to location: String) { redirects.append((pathContains, location)) }

    func folderPath(_ id: String, mailbox: String? = nil) -> String {
        let box = mailboxes[(mailbox ?? primary).lowercased()]!
        var parts: [String] = []
        var cur: String? = id
        while let c = cur, let f = box.folders[c] { parts.insert(f.name, at: 0); cur = f.parent }
        return parts.joined(separator: "/")
    }

    func messageIDs(mailbox: String? = nil) -> Set<String> { Set(mailboxes[(mailbox ?? primary).lowercased()]!.messages.keys) }
    func mimeOf(_ id: String, mailbox: String? = nil) -> Data? { mailboxes[(mailbox ?? primary).lowercased()]!.messages[id]?.mime }
    var totalValueDownloads: Int { valueDownloads.values.reduce(0, +) }

    static func mime(_ id: String) -> Data {
        Data(("Message-ID: <\(id)@contoso.example>\r\nFrom: Asha <asha@contoso.com>\r\nTo: ravi@example.org\r\n"
              + "Subject: Graph \(id) – ü\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\nMIME-Version: 1.0\r\n"
              + "Content-Type: text/plain; charset=utf-8\r\n\r\nBody \(id) end\r\n").utf8)
    }

    // MARK: Wire helpers

    private func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> GraphHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return body(status, data, headers: headers.merging(["content-type": "application/json"]) { a, _ in a })
    }

    private func body(_ status: Int, _ data: Data, headers: [String: String] = [:], chunk: Int? = nil) -> GraphHTTPResponse {
        let size = max(1, chunk ?? max(1, data.count))
        let stream = AsyncThrowingStream<Data, Error> { c in
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + size)
                c.yield(data.subdata(in: offset..<end))
                offset = end
            }
            c.finish()
        }
        return GraphHTTPResponse(status: status, headers: headers, body: stream)
    }

    private func error(_ status: Int, _ code: String, headers: [String: String] = [:]) -> GraphHTTPResponse {
        json(status, ["error": ["code": code, "message": code]], headers: headers)
    }

    private func wireID(_ m: Message, immutable: Bool) -> String { immutable ? m.id : "\(m.id)-r\(m.moves)" }

    private func resolve(_ wire: String, in box: Mailbox) -> Message? {
        if let m = box.messages[wire] { return m }
        for m in box.messages.values where "\(m.id)-r\(m.moves)" == wire { return m }
        return nil
    }

    private func link(_ prefix: String, _ path: String, _ query: [(String, String)]) -> String {
        var c = URLComponents()
        c.scheme = "https"; c.host = Self.host
        c.percentEncodedPath = "/v1.0/" + prefix + "/" + path
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!.absoluteString
    }

    // MARK: Transport

    func send(_ request: GraphHTTPRequest) async throws -> GraphHTTPResponse {
        guard request.url.host?.lowercased() == Self.host else {
            foreignRequests.append(request)
            return body(200, Data("stolen".utf8))
        }
        requests.append(request)
        let rawPath = request.url.path
        if let i = redirects.firstIndex(where: { rawPath.contains($0.pathContains) }) {
            let r = redirects.remove(at: i)
            return body(302, Data(), headers: ["location": r.location])
        }
        if let acceptedToken, request.header("Authorization") != "Bearer \(acceptedToken)" {
            return error(401, "InvalidAuthenticationToken")
        }
        if let i = failures.firstIndex(where: { rawPath.contains($0.pathContains) || request.url.absoluteString.contains($0.pathContains) }) {
            let f = failures[i]
            if f.times <= 1 { failures.remove(at: i) } else { failures[i].times -= 1 }
            return error(f.status, f.code ?? "Scripted", headers: f.headers)
        }
        let immutable = (request.header("Prefer") ?? "").contains(#"IdType="ImmutableId""#)
        let maxPage = (request.header("Prefer") ?? "").components(separatedBy: "odata.maxpagesize=").dropFirst().first
            .flatMap { Int($0.prefix { $0.isNumber }) }
        let segments = request.url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        guard segments.first == "v1.0", segments.count >= 2 else { return error(400, "BadRequest") }
        var rest = Array(segments.dropFirst())
        let key: String
        let prefix: String
        if rest.first == "me" {
            key = primary; prefix = "me"; rest.removeFirst()
        } else if rest.first == "users", rest.count >= 2 {
            key = rest[1].lowercased(); prefix = "users/" + GraphAdapter.escape(rest[1]); rest.removeFirst(2)
        } else { return error(400, "BadRequest") }
        if denied.contains(key) { return error(403, "ErrorAccessDenied") }
        guard let box = mailboxes[key] else { return error(404, "ErrorInvalidUser") }
        let query = Dictionary((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let top = Int(query["$top"] ?? "") ?? folderPageSize
        let skip = Int(query["$skip"] ?? "") ?? 0
        let hidden = query["includeHiddenFolders"] == "true"

        func folderJSON(_ f: Folder) -> [String: Any] {
            let children = box.folderOrder.filter { box.folders[$0]?.parent == f.id && (hidden || box.folders[$0]?.hidden == false) }
            return ["id": f.id, "displayName": f.name, "parentFolderId": f.parent, "childFolderCount": children.count]
        }
        func folderID(_ s: String) -> String? { box.wellKnown[s] ?? (box.folders[s] != nil ? s : nil) }
        func listFolders(parent: String, path: String) -> GraphHTTPResponse {
            let all = box.folderOrder.compactMap { box.folders[$0] }.filter { $0.parent == parent && (hidden || !$0.hidden) }
            let size = min(top, folderPageSize)
            let page = all.dropFirst(skip).prefix(size)
            var out: [String: Any] = ["value": page.map(folderJSON)]
            if skip + size < all.count {
                var q: [(String, String)] = [("$select", query["$select"] ?? ""), ("$top", String(top)), ("$skip", String(skip + size))]
                if hidden { q.append(("includeHiddenFolders", "true")) }
                out["@odata.nextLink"] = link(prefix, path, q)
            }
            return json(200, out)
        }

        switch rest.count {
        case 1 where rest[0] == "mailFolders":
            return listFolders(parent: box.rootID, path: "mailFolders")
        case 1 where rest[0] == "messages":
            collectionRequests += 1
            return json(200, ["value": box.messages.values.map { ["id": wireID($0, immutable: immutable)] }])
        case 2 where rest[0] == "mailFolders":
            guard let id = folderID(rest[1]) else { return error(404, "ErrorItemNotFound") }
            if id == box.rootID { return json(200, ["id": id, "displayName": "Top of Information Store", "childFolderCount": 1]) }
            return json(200, folderJSON(box.folders[id]!))
        case 3 where rest[0] == "mailFolders" && rest[2] == "childFolders":
            guard let id = folderID(rest[1]) else { return error(404, "ErrorItemNotFound") }
            return listFolders(parent: id, path: "mailFolders/\(GraphAdapter.escape(rest[1]))/childFolders")
        case 3 where rest[0] == "mailFolders" && rest[2] == "messages":
            guard let id = folderID(rest[1]) else { return error(404, "ErrorItemNotFound") }
            let all = box.messages.values.filter { $0.folder == id }.sorted { $0.created < $1.created }
            let page = all.dropFirst(skip).prefix(top)
            var out: [String: Any] = ["value": page.map { ["id": wireID($0, immutable: immutable), "changeKey": "ck\($0.changeKey)", "parentFolderId": $0.folder] }]
            if skip + top < all.count {
                out["@odata.nextLink"] = link(prefix, "mailFolders/\(GraphAdapter.escape(rest[1]))/messages",
                                              [("$select", query["$select"] ?? ""), ("$top", String(top)), ("$skip", String(skip + top))])
            }
            return json(200, out)
        case 4 where rest[0] == "mailFolders" && rest[2] == "messages" && rest[3] == "delta":
            guard let id = folderID(rest[1]) else { return error(404, "ErrorItemNotFound") }
            return delta(box: box, folder: id, prefix: prefix, pathFolder: rest[1], query: query, immutable: immutable,
                         pageSize: maxPage ?? 10)
        case 2 where rest[0] == "messages":
            guard let m = resolve(rest[1], in: box) else { return error(404, "ErrorItemNotFound") }
            return json(200, ["id": wireID(m, immutable: immutable), "parentFolderId": m.folder, "changeKey": "ck\(m.changeKey)",
                              "receivedDateTime": "2025-01-06T10:00:00Z", "isRead": m.isRead,
                              "hasAttachments": !m.attachments.isEmpty, "categories": ["Blue"],
                              "internetMessageId": "<\(m.id)@contoso.example>", "flag": ["flagStatus": "flagged"]])
        case 3 where rest[0] == "messages" && rest[2] == "$value":
            guard let m = resolve(rest[1], in: box) else { return error(404, "ErrorItemNotFound") }
            valueDownloads[m.id, default: 0] += 1
            return body(200, m.mime, headers: ["content-type": "message/rfc822", "content-length": String(m.mime.count)], chunk: chunkSize)
        case 3 where rest[0] == "messages" && rest[2] == "attachments":
            guard let m = resolve(rest[1], in: box) else { return error(404, "ErrorItemNotFound") }
            return json(200, ["value": m.attachments.enumerated().map { i, a in
                ["@odata.type": a.type, "id": "att\(i)", "name": a.name, "contentType": a.contentType,
                 "size": a.size, "isInline": a.isInline] as [String: Any] }])
        default:
            return error(400, "BadRequest")
        }
    }

    // Delta tokens: "<folder>~<seq>~<epoch>"; skip tokens: "<folder>~<from>~<to>~<epoch>~<offset>".
    private func delta(box: Mailbox, folder: String, prefix: String, pathFolder: String, query: [String: String],
                       immutable: Bool, pageSize: Int) -> GraphHTTPResponse {
        let path = "mailFolders/\(GraphAdapter.escape(pathFolder))/messages/delta"
        let select = query["$select"] ?? ""
        var from: Int, to: Int, offset: Int
        if let token = query["$deltatoken"] {
            if token == "latest" {
                guard supportsLatestDeltaToken else {
                    // Initial round from the beginning, paged.
                    from = 0; to = seq; offset = 0
                    return deltaPage(box: box, folder: folder, prefix: prefix, path: path, select: select, from: from, to: to,
                                     offset: offset, immutable: immutable, pageSize: pageSize)
                }
                return json(200, ["value": [], "@odata.deltaLink": link(prefix, path, [("$select", select), ("$deltatoken", "\(folder)~\(seq)~\(epoch)")])])
            }
            let p = token.split(separator: "~").map(String.init)
            guard p.count == 3, p[0] == folder, let s = Int(p[1]), Int(p[2]) == epoch else { return error(410, "SyncStateNotFound") }
            from = s; to = seq; offset = 0
            if emptyContinuationPages > 0 {
                emptyContinuationPages -= 1; emptyPagesServed += 1
                return json(200, ["value": [], "@odata.nextLink": link(prefix, path, [("$select", select), ("$skiptoken", "\(folder)~\(from)~\(to)~\(epoch)~0")])])
            }
        } else if let token = query["$skiptoken"] {
            let p = token.split(separator: "~").map(String.init)
            guard p.count == 5, p[0] == folder, let f = Int(p[1]), let t = Int(p[2]), Int(p[3]) == epoch, let o = Int(p[4]) else {
                return error(410, "SyncStateNotFound")
            }
            from = f; to = t; offset = o
            if emptyContinuationPages > 0 {
                emptyContinuationPages -= 1; emptyPagesServed += 1
                return json(200, ["value": [], "@odata.nextLink": link(prefix, path, [("$select", select), ("$skiptoken", token)])])
            }
        } else {
            from = 0; to = seq; offset = 0
        }
        return deltaPage(box: box, folder: folder, prefix: prefix, path: path, select: select, from: from, to: to,
                         offset: offset, immutable: immutable, pageSize: pageSize)
    }

    private func deltaPage(box: Mailbox, folder: String, prefix: String, path: String, select: String,
                           from: Int, to: Int, offset: Int, immutable: Bool, pageSize: Int) -> GraphHTTPResponse {
        // The last event per message in this folder within (from, to].
        var order: [String] = []
        var seen = Set<String>()
        for entry in box.log.reversed() where entry.folder == folder && entry.seq > from && entry.seq <= to {
            if seen.insert(entry.id).inserted { order.insert(entry.id, at: 0) }
        }
        let entries: [[String: Any]] = order.map { id in
            if let m = box.messages[id], m.folder == folder {
                return ["id": wireID(m, immutable: immutable), "changeKey": "ck\(m.changeKey)", "parentFolderId": m.folder]
            }
            let wire = box.messages[id].map { wireID($0, immutable: immutable) } ?? id
            return ["id": wire, "@removed": ["reason": "deleted"]]
        }
        let page = Array(entries.dropFirst(offset).prefix(pageSize))
        if offset + pageSize < entries.count {
            return json(200, ["value": page, "@odata.nextLink": link(prefix, path, [("$select", select), ("$skiptoken", "\(folder)~\(from)~\(to)~\(epoch)~\(offset + pageSize)")])])
        }
        return json(200, ["value": page, "@odata.deltaLink": link(prefix, path, [("$select", select), ("$deltatoken", "\(folder)~\(to)~\(epoch)")])])
    }
}
