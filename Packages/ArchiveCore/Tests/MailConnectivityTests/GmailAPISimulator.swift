//
//  GmailAPISimulator.swift
//  MailConnectivityTests
//
//  V4-05: a deterministic Gmail API v1 server in memory, reached through the
//  adapter's injected `GmailHTTPTransport` (no network). It answers JSON the
//  way Gmail does — labels, paged messages.list (newest first, opaque page
//  tokens), messages.get?format=raw (base64url, optionally padded and with
//  "=" escaped as =, streamed in small chunks that split JSON tokens),
//  profile historyId, paged history.list with messagesAdded / labelsAdded /
//  labelsRemoved / messagesDeleted, an expirable history floor — plus
//  injected failures (Gmail error JSON, Retry-After, redirects, cut-off bodies).
//

import Foundation
@testable import MailConnectivity

actor GmailAPISimulator: GmailHTTPTransport {
    struct Message { var raw: Data; var labels: [String]; let seq: Int; let internalDateMS: Int64; var historyID: Int; let thread: String }
    struct Record { let id: Int; var added: [(String, [String])] = []; var deleted: [String] = []
                    var labelsAdded: [(String, [String], [String])] = []; var labelsRemoved: [(String, [String], [String])] = [] }

    enum Match: Sendable, Equatable {
        case any, profile, labels, list(label: String?), message(String), history
    }
    struct Canned: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    // Mailbox.
    private(set) var labels: [(id: String, name: String, type: String)] = []
    private(set) var messages: [String: Message] = [:]
    private var seq = 0
    private(set) var historyID = 4_000
    private var records: [Record] = []
    private var historyFloor = 0

    // Behaviour.
    var chunkSize = 61
    var padBase64 = false
    var escapeEquals = false
    var requiredToken: String?
    private var injected: [(Match, Canned)] = []
    /// Message ids whose body is cut off after this many bytes (then a connection error).
    private var cutOff: [String: Int] = [:]

    // Observations.
    private(set) var requests: [GmailHTTPRequest] = []
    private(set) var foreignRequests: [GmailHTTPRequest] = []
    private(set) var gets: [String: Int] = [:]
    private(set) var listPages = 0
    private(set) var historyPages = 0
    private(set) var authorizationsSeen: [String] = []

    func set(chunkSize: Int? = nil, pad: Bool? = nil, escapeEquals: Bool? = nil, requiredToken: String?? = nil) {
        if let chunkSize { self.chunkSize = chunkSize }
        if let pad { padBase64 = pad }
        if let escapeEquals { self.escapeEquals = escapeEquals }
        if let requiredToken { self.requiredToken = requiredToken }
    }

    // MARK: Mailbox setup and mutations

    func addLabel(_ id: String, name: String, system: Bool = false) {
        labels.append((id, name, system ? "system" : "user"))
    }

    func addStandardSystemLabels() {
        for id in ["INBOX", "SENT", "DRAFT", "SPAM", "TRASH", "UNREAD", "STARRED", "IMPORTANT", "CATEGORY_UPDATES", "CHAT"] {
            addLabel(id, name: id, system: true)
        }
    }

    func renameLabel(_ id: String, to name: String) {
        if let i = labels.firstIndex(where: { $0.id == id }) { labels[i].name = name }
    }

    func add(_ id: String, raw: Data, labels: [String]) {
        seq += 1; historyID += 1
        messages[id] = Message(raw: raw, labels: labels, seq: seq, internalDateMS: 1_736_137_800_000 + Int64(seq) * 60_000,
                               historyID: historyID, thread: "t\(id)")
        records.append(Record(id: historyID, added: [(id, labels)]))
    }

    func modify(_ id: String, add: [String] = [], remove: [String] = []) {
        guard var message = messages[id] else { return }
        historyID += 1
        var now = message.labels.filter { !remove.contains($0) }
        for label in add where !now.contains(label) { now.append(label) }
        message.labels = now; message.historyID = historyID
        messages[id] = message
        var record = Record(id: historyID)
        if !add.isEmpty { record.labelsAdded = [(id, now, add)] }
        if !remove.isEmpty { record.labelsRemoved = [(id, now, remove)] }
        records.append(record)
    }

    func delete(_ id: String) {
        guard messages.removeValue(forKey: id) != nil else { return }
        historyID += 1
        records.append(Record(id: historyID, deleted: [id]))
    }

    /// Every start id older than the current one is now "too old" (HTTP 404).
    func expireHistory() { historyFloor = historyID }

    func inject(_ match: Match, _ canned: Canned, times: Int = 1) {
        for _ in 0..<times { injected.append((match, canned)) }
    }

    func cutOffBody(of id: String, after bytes: Int) { cutOff[id] = bytes }

    func raw(_ id: String) -> Data? { messages[id]?.raw }
    func getCount(_ id: String) -> Int { gets[id] ?? 0 }
    var totalGets: Int { gets.values.reduce(0, +) }

    // MARK: Transport

    func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse {
        guard request.url.host == "gmail.googleapis.com", request.url.scheme == "https" else {
            foreignRequests.append(request)
            return Self.response(request, status: 200, json: "{}")
        }
        requests.append(request)
        let auth = request.headers["Authorization"] ?? ""
        authorizationsSeen.append(auth)
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let prefix = "/gmail/v1/users/me/"
        guard components.path.hasPrefix(prefix) else { return Self.error(request, 404, "notFound", "Not Found") }
        let path = String(components.path.dropFirst(prefix.count))
        let match: Match
        switch path {
        case "profile": match = .profile
        case "labels": match = .labels
        case "messages": match = .list(label: value("labelIds"))
        case "history": match = .history
        default:
            guard path.hasPrefix("messages/") else { return Self.error(request, 404, "notFound", "Not Found") }
            match = .message(String(path.dropFirst("messages/".count)))
        }

        if let requiredToken, auth != "Bearer \(requiredToken)" {
            return Self.error(request, 401, "authError", "Invalid Credentials")
        }
        if let i = injected.firstIndex(where: { $0.0 == match || $0.0 == .any }) {
            let canned = injected.remove(at: i).1
            return GmailHTTPResponse(status: canned.status, headers: canned.headers, url: request.url,
                                     body: GmailByteStream.of(canned.body, chunkSize: chunkSize))
        }

        switch match {
        case .profile:
            return Self.response(request, status: 200,
                                 json: #"{"emailAddress":"asha@example.com","messagesTotal":\#(messages.count),"historyId":"\#(historyID)"}"#)
        case .labels:
            let items = labels.map { #"{"id":"\#($0.id)","name":"\#(Self.jsonEscape($0.name))","type":"\#($0.type)"}"# }
            return Self.response(request, status: 200, json: #"{"labels":[\#(items.joined(separator: ","))]}"#)
        case .list(let label):
            listPages += 1
            let includeSpamTrash = value("includeSpamTrash") == "true"
            let max = Int(value("maxResults") ?? "100") ?? 100
            let before = value("pageToken").map { token -> Int in
                guard token.hasPrefix("pt-"), let n = Int(token.dropFirst(3)) else { return -1 }
                return n
            }
            if before == -1 { return Self.error(request, 400, "invalidArgument", "Invalid pageToken") }
            let all = messages.filter { _, m in
                (label == nil || m.labels.contains(label!))
                    && (includeSpamTrash || (!m.labels.contains("SPAM") && !m.labels.contains("TRASH")))
                    && (before == nil || m.seq < before!)
            }.sorted { $0.value.seq > $1.value.seq }
            let page = all.prefix(max)
            let items = page.map { #"{"id":"\#($0.key)","threadId":"\#($0.value.thread)"}"# }
            var json = #"{"messages":[\#(items.joined(separator: ","))],"resultSizeEstimate":\#(all.count)"#
            if all.count > max, let last = page.last { json += #","nextPageToken":"pt-\#(last.value.seq)""# }
            return Self.response(request, status: 200, json: json + "}")
        case .message(let id):
            gets[id, default: 0] += 1
            guard value("format") == "raw" else { return Self.error(request, 400, "invalidArgument", "format must be raw") }
            guard let message = messages[id] else { return Self.error(request, 404, "notFound", "Requested entity was not found.") }
            var encoded = message.raw.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            if !padBase64 { encoded = encoded.replacingOccurrences(of: "=", with: "") }
            if escapeEquals { encoded = encoded.replacingOccurrences(of: "=", with: "\\u003d") }
            let labelsJSON = message.labels.map { "\"\($0)\"" }.joined(separator: ",")
            // "raw" is deliberately NOT last, and a decoy "raw" sits one level down.
            let json = #"{"id":"\#(id)","threadId":"\#(message.thread)","labelIds":[\#(labelsJSON)],"#
                + #""snippet":"Grüße \"raw\": {not json} \\ end","decoy":{"raw":"!!notbase64!!"},"#
                + #""raw":"\#(encoded)","sizeEstimate":\#(message.raw.count + 37),"#
                + #""historyId":"\#(message.historyID)","internalDate":"\#(message.internalDateMS)"}"#
            let data = Data(json.utf8)
            if let cut = cutOff.removeValue(forKey: id) {
                let head = data.prefix(cut)
                let size = chunkSize
                let stream = AsyncThrowingStream<Data, Error> { c in
                    var offset = 0
                    while offset < head.count {
                        let end = min(head.count, offset + size)
                        c.yield(head.subdata(in: offset..<end)); offset = end
                    }
                    c.finish(throwing: URLError(.networkConnectionLost))
                }
                return GmailHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], url: request.url,
                                         body: GmailByteStream(stream))
            }
            return GmailHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], url: request.url,
                                     body: GmailByteStream.of(data, chunkSize: chunkSize))
        case .history:
            historyPages += 1
            guard let start = Int(value("startHistoryId") ?? ""), start >= historyFloor else {
                return Self.error(request, 404, "notFound", "Requested entity was not found.")
            }
            let max = Int(value("maxResults") ?? "100") ?? 100
            var after = start
            if let token = value("pageToken") {
                guard token.hasPrefix("hp-"), let n = Int(token.dropFirst(3)) else {
                    return Self.error(request, 400, "invalidArgument", "Invalid pageToken")
                }
                after = n
            }
            let pending = records.filter { $0.id > after }
            let page = pending.prefix(max)
            var items: [String] = []
            for record in page {
                var fields = [#""id":"\#(record.id)""#]
                func msg(_ id: String, _ labels: [String]?) -> String {
                    let labelPart = labels.map { #","labelIds":[\#($0.map { "\"\($0)\"" }.joined(separator: ","))]"# } ?? ""
                    return #"{"id":"\#(id)","threadId":"t\#(id)"\#(labelPart)}"#
                }
                if !record.added.isEmpty {
                    fields.append(#""messagesAdded":[\#(record.added.map { #"{"message":\#(msg($0.0, $0.1))}"# }.joined(separator: ","))]"#)
                }
                if !record.labelsAdded.isEmpty {
                    fields.append(#""labelsAdded":[\#(record.labelsAdded.map { #"{"message":\#(msg($0.0, $0.1)),"labelIds":[\#($0.2.map { "\"\($0)\"" }.joined(separator: ","))]}"# }.joined(separator: ","))]"#)
                }
                if !record.labelsRemoved.isEmpty {
                    fields.append(#""labelsRemoved":[\#(record.labelsRemoved.map { #"{"message":\#(msg($0.0, $0.1)),"labelIds":[\#($0.2.map { "\"\($0)\"" }.joined(separator: ","))]}"# }.joined(separator: ","))]"#)
                }
                if !record.deleted.isEmpty {
                    fields.append(#""messagesDeleted":[\#(record.deleted.map { #"{"message":\#(msg($0, nil))}"# }.joined(separator: ","))]"#)
                }
                items.append("{" + fields.joined(separator: ",") + "}")
            }
            var json = #"{"history":[\#(items.joined(separator: ","))],"historyId":"\#(historyID)""#
            if pending.count > page.count, let last = page.last { json += #","nextPageToken":"hp-\#(last.id)""# }
            return Self.response(request, status: 200, json: json + "}")
        case .any:
            return Self.error(request, 500, "backendError", "unreachable")
        }
    }

    // MARK: Helpers

    static func jsonEscape(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst(2).dropLast(2))
    }

    static func response(_ request: GmailHTTPRequest, status: Int, json: String, headers: [String: String] = [:]) -> GmailHTTPResponse {
        var h = headers; h["Content-Type"] = "application/json; charset=UTF-8"
        return GmailHTTPResponse(status: status, headers: h, url: request.url, body: GmailByteStream.of(Data(json.utf8), chunkSize: 37))
    }

    static func errorJSON(_ status: Int, _ reason: String, _ message: String, domain: String = "global") -> Data {
        Data(#"{"error":{"code":\#(status),"message":"\#(message)","errors":[{"message":"\#(message)","domain":"\#(domain)","reason":"\#(reason)"}],"status":"X"}}"#.utf8)
    }

    static func error(_ request: GmailHTTPRequest, _ status: Int, _ reason: String, _ message: String) -> GmailHTTPResponse {
        GmailHTTPResponse(status: status, headers: ["Content-Type": "application/json"], url: request.url,
                          body: GmailByteStream.of(errorJSON(status, reason, message)))
    }
}
