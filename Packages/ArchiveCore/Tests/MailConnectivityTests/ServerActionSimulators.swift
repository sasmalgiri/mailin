//
//  ServerActionSimulators.swift
//  MailConnectivityTests
//
//  V4-11: deterministic Gmail and Microsoft Graph mailboxes for server
//  actions, served through `SendHTTPTransport` (no network). Each keeps the
//  mailbox state, every request it received, and a hook that lets "another
//  client" change a message at an exact moment.
//

import Foundation
@testable import MailConnectivity

final class ActionBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

/// Hands out one token for any audience; counts every call.
final class CountingTokens: AccessTokenSource, @unchecked Sendable {
    let token: String
    let calls = ActionBox(0)
    init(_ token: String = "change-token") { self.token = token }
    func accessToken(for account: UUID, audience: String) async throws -> String { calls.mutate { $0 += 1 }; return token }
    func refreshAfterRejection(account: UUID, audience: String) async throws -> String { calls.mutate { $0 += 1 }; return token }
}

// MARK: - Gmail

final class GmailActionSimulator: SendHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String: [String]] = [:]
    private var _requests: [SendHTTPRequest] = []
    /// Called before a mutating request is applied (method, message id).
    var beforeMutation: (@Sendable (String, String, GmailActionSimulator) -> Void)?
    /// The next mutating request is applied, then the connection "drops" (no reply).
    var dropReplyAfterApplying = false

    func put(_ id: String, _ l: [String]) { lock.withLock { labels[id] = l } }
    func remove(_ id: String) { lock.withLock { labels[id] = nil } }
    func labels(of id: String) -> [String]? { lock.withLock { labels[id] } }
    var requests: [SendHTTPRequest] { lock.withLock { _requests } }
    var mutations: [SendHTTPRequest] { requests.filter { $0.method != "GET" } }

    struct Dropped: Error {}

    func perform(_ request: SendHTTPRequest) async throws -> SendHTTPResponse {
        lock.withLock { _requests.append(request) }
        let prefix = "/gmail/v1/users/me/messages/"
        guard request.url.host == "gmail.googleapis.com", request.url.path.hasPrefix(prefix) else { return Self.json(404, #"{"error":{"code":404}}"#) }
        let rest = String(request.url.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard let id = rest.first else { return Self.json(404, "{}") }
        if request.method == "GET" {
            guard let l = labels(of: id) else { return Self.json(404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            return Self.json(200, Self.message(id, l))
        }
        beforeMutation?(request.method, id, self)
        let result: SendHTTPResponse = lock.withLock {
            guard var l = labels[id] else { return Self.json(404, #"{"error":{"code":404}}"#) }
            switch rest.count > 1 ? rest[1] : "" {
            case "modify":
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: [String]] ?? [:]
                for a in body["addLabelIds"] ?? [] where !l.contains(a) { l.append(a) }
                l.removeAll { (body["removeLabelIds"] ?? []).contains($0) }
            case "trash":
                if !l.contains("TRASH") { l.append("TRASH") }
                l.removeAll { $0 == "INBOX" }
            case "untrash":
                l.removeAll { $0 == "TRASH" }
                if !l.contains("INBOX") { l.append("INBOX") }
            default:
                return Self.json(404, "{}")
            }
            labels[id] = l
            return Self.json(200, Self.message(id, l))
        }
        if dropReplyAfterApplying { dropReplyAfterApplying = false; throw Dropped() }
        return result
    }

    static func message(_ id: String, _ l: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["id": id, "labelIds": l, "historyId": "900"])
        return String(decoding: data, as: UTF8.self)
    }

    static func json(_ status: Int, _ body: String) -> SendHTTPResponse {
        SendHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }
}

// MARK: - Microsoft Graph

final class GraphActionSimulator: SendHTTPTransport, @unchecked Sendable {
    struct Message { var folder: String; var isRead: Bool; var flagged: Bool }
    private let lock = NSLock()
    private var messages: [String: Message] = [:]
    private var _requests: [SendHTTPRequest] = []
    let wellKnown = ["inbox": "AAMk-inbox", "deleteditems": "AAMk-deleted", "archive": "AAMk-archive"]
    var beforeMutation: (@Sendable (String, GraphActionSimulator) -> Void)?

    func put(_ id: String, _ m: Message) { lock.withLock { messages[id] = m } }
    func message(_ id: String) -> Message? { lock.withLock { messages[id] } }
    var ids: [String] { lock.withLock { Array(messages.keys).sorted() } }
    var requests: [SendHTTPRequest] { lock.withLock { _requests } }
    var mutations: [SendHTTPRequest] { requests.filter { $0.method != "GET" } }

    func perform(_ request: SendHTTPRequest) async throws -> SendHTTPResponse {
        lock.withLock { _requests.append(request) }
        let parts = request.url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        // /v1.0/me/…
        guard request.url.host == "graph.microsoft.com", parts.count >= 3, parts[0] == "v1.0", parts[1] == "me" else {
            return GmailActionSimulator.json(404, #"{"error":{"code":"ErrorItemNotFound"}}"#)
        }
        let immutable = request.headers["Prefer"]?.contains(#"IdType="ImmutableId""#) == true
        if parts[2] == "mailFolders", parts.count == 4 {
            guard let id = wellKnown[parts[3]] else { return GmailActionSimulator.json(404, "{}") }
            return GmailActionSimulator.json(200, #"{"id":"\#(id)"}"#)
        }
        guard parts[2] == "messages", parts.count >= 4 else { return GmailActionSimulator.json(404, "{}") }
        let id = parts[3]
        if request.method != "GET" { beforeMutation?(id, self) }
        return lock.withLock {
            guard var m = messages[id] else { return GmailActionSimulator.json(404, #"{"error":{"code":"ErrorItemNotFound","message":"Not found"}}"#) }
            switch (request.method, parts.count > 4 ? parts[4] : "") {
            case ("GET", ""):
                return GmailActionSimulator.json(200, Self.json(id, m))
            case ("PATCH", ""):
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
                if let r = body["isRead"] as? Bool { m.isRead = r }
                if let f = body["flag"] as? [String: String] { m.flagged = f["flagStatus"] == "flagged" }
                messages[id] = m
                return GmailActionSimulator.json(200, Self.json(id, m))
            case ("POST", "move"):
                let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String] ?? [:]
                guard let dest = body["destinationId"] else { return GmailActionSimulator.json(400, "{}") }
                m.folder = wellKnown[dest.lowercased()] ?? dest
                // Without the immutable-id preference Exchange returns a NEW id.
                let newID = immutable ? id : "moved-\(id)"
                messages[id] = nil
                messages[newID] = m
                return GmailActionSimulator.json(201, Self.json(newID, m))
            default:
                return GmailActionSimulator.json(405, "{}")
            }
        }
    }

    static func json(_ id: String, _ m: Message) -> String {
        #"{"id":"\#(id)","isRead":\#(m.isRead),"parentFolderId":"\#(m.folder)","changeKey":"ck","flag":{"flagStatus":"\#(m.flagged ? "flagged" : "notFlagged")"}}"#
    }
}
