//
//  IMAPTestServer.swift
//  MailConnectivityTests
//
//  V4-07: two IMAP test doubles, neither of which leaves this Mac.
//   • `LocalIMAPServer` — an in-process IMAP server on 127.0.0.1 (NWListener,
//     ephemeral port): mailboxes with UIDVALIDITY / UIDNEXT / MODSEQ, LIST
//     with SPECIAL-USE, NAMESPACE, ENABLE, EXAMINE, UID FETCH (BODY.PEEK[] and,
//     for the read-only proof, BODY[] which sets \Seen like a real server),
//     UID SEARCH / ESEARCH, CHANGEDSINCE / VANISHED, IDLE, PLAIN / LOGIN /
//     XOAUTH2. Every client line is kept in a transcript.
//   • `ScriptedIMAPTransport` — a pure byte-stream fake: the test decides
//     exactly which bytes arrive in which packet (1-byte packets, splits
//     inside UTF-8, literals and CRLFs).
//

import Foundation
import Network
@testable import MailConnectivity

// MARK: - Model

final class IMAPServerModel: @unchecked Sendable {
    struct Message {
        var uid: UInt32
        var bytes: Data
        var flags: [String]
        var modseq: UInt64
        var internalDate = "06-Jan-2025 10:00:00 +0530"
    }
    struct Mailbox {
        var name: String
        var attributes: [String]
        var uidValidity: UInt32
        var uidNext: UInt32 = 1
        var messages: [Message] = []
        var modseq: UInt64 = 1
        var expunged: [(uid: UInt32, modseq: UInt64)] = []
    }

    private let lock = NSLock()
    private var _mailboxes: [Mailbox] = []
    private var _transcript: [String] = []
    private var _connections = 0
    private var nextValidity: UInt32 = 3_857_529_045

    // Behaviour (set before the test runs).
    var login = "asha"
    var password = "app-secret-1"
    var oauthToken: String?
    var delimiter = "/"
    var namespacePrefix = ""
    var preAuthCapabilities = ["IMAP4rev1", "AUTH=PLAIN", "SASL-IR", "LITERAL+"]
    var postAuthCapabilities = ["IMAP4rev1", "LITERAL+", "ENABLE", "NAMESPACE", "LIST-EXTENDED", "SPECIAL-USE",
                                "UTF8=ACCEPT", "CONDSTORE", "QRESYNC", "ESEARCH", "IDLE", "UIDPLUS"]
    var greeting = "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR LITERAL+] mailin test server ready"
    var offerSTARTTLS = false
    /// 0 = each response in one send; otherwise sent in pieces of this many bytes.
    var writeChunk = 0
    /// Put UID after BODY[] in FETCH responses (attribute order is the server's).
    var uidAfterBody = false
    /// Send mailbox names as literals in LIST.
    var namesAsLiterals = false
    /// Close the connection (once) when this UID's body is requested.
    var dropOnBodyOfUID: UInt32?
    /// Seconds before a body FETCH is answered.
    var bodyDelay: TimeInterval = 0
    /// Tagged NO with this code to authentication (e.g. "AUTHENTICATIONFAILED").
    var authFailureCode: String?

    var mailboxes: [Mailbox] { lock.withLock { _mailboxes } }
    var transcript: [String] { lock.withLock { _transcript } }
    var connections: Int { lock.withLock { _connections } }

    func record(_ line: String) { lock.withLock { _transcript.append(line) } }
    func connected() { lock.withLock { _connections += 1 } }
    func clearTranscript() { lock.withLock { _transcript = [] } }
    func mutate<R>(_ body: (inout [Mailbox]) -> R) -> R { lock.withLock { body(&_mailboxes) } }

    func takeDrop(_ uid: UInt32) -> Bool {
        lock.withLock { if dropOnBodyOfUID == uid { dropOnBodyOfUID = nil; return true }; return false }
    }

    @discardableResult
    func addMailbox(_ name: String, attributes: [String] = ["\\HasNoChildren"]) -> Int {
        lock.withLock {
            nextValidity += 7
            _mailboxes.append(Mailbox(name: name, attributes: attributes, uidValidity: nextValidity))
            return _mailboxes.count - 1
        }
    }

    @discardableResult
    func add(_ bytes: Data, to name: String, flags: [String] = []) -> UInt32 {
        lock.withLock {
            guard let i = _mailboxes.firstIndex(where: { $0.name == name }) else { fatalError("no mailbox \(name)") }
            let uid = _mailboxes[i].uidNext
            _mailboxes[i].uidNext += 1
            _mailboxes[i].modseq += 1
            _mailboxes[i].messages.append(Message(uid: uid, bytes: bytes, flags: flags, modseq: _mailboxes[i].modseq))
            return uid
        }
    }

    /// Leaves a UID gap (UIDs are not dense on real servers).
    func skipUIDs(_ n: UInt32, in name: String) {
        lock.withLock {
            if let i = _mailboxes.firstIndex(where: { $0.name == name }) { _mailboxes[i].uidNext += n }
        }
    }

    func expunge(_ uid: UInt32, from name: String) {
        lock.withLock {
            guard let i = _mailboxes.firstIndex(where: { $0.name == name }) else { return }
            _mailboxes[i].messages.removeAll { $0.uid == uid }
            _mailboxes[i].modseq += 1
            _mailboxes[i].expunged.append((uid, _mailboxes[i].modseq))
        }
    }

    func rename(_ old: String, to new: String) {
        lock.withLock {
            if let i = _mailboxes.firstIndex(where: { $0.name == old }) { _mailboxes[i].name = new }
        }
    }

    /// A UIDVALIDITY change: every message renumbered from 1 (new UIDs may
    /// now name different messages than before).
    func resetUIDValidity(_ name: String, contents: [Data]) {
        lock.withLock {
            guard let i = _mailboxes.firstIndex(where: { $0.name == name }) else { return }
            nextValidity += 101
            _mailboxes[i].uidValidity = nextValidity
            _mailboxes[i].modseq += 1
            _mailboxes[i].messages = contents.enumerated().map {
                Message(uid: UInt32($0.offset + 1), bytes: $0.element, flags: [], modseq: _mailboxes[i].modseq)
            }
            _mailboxes[i].uidNext = UInt32(contents.count + 1)
            _mailboxes[i].expunged = []
        }
    }

    func flags(of uid: UInt32, in name: String) -> [String]? {
        lock.withLock { _mailboxes.first { $0.name == name }?.messages.first { $0.uid == uid }?.flags }
    }

    // MARK: V4-11 server actions (served only when `serveServerActions` is on)

    /// Off: STORE / COPY / MOVE / EXPUNGE answer BAD, as for the read-only tests.
    var serveServerActions = false
    /// Called with each client command line before it is served ("another
    /// client" changes the mailbox at an exact moment).
    var onCommand: (@Sendable (String, IMAPServerModel) -> Void)?

    func setFlags(_ uid: UInt32, in name: String, add: [String], remove: [String]) -> Bool {
        lock.withLock {
            guard let i = _mailboxes.firstIndex(where: { $0.name == name }),
                  let k = _mailboxes[i].messages.firstIndex(where: { $0.uid == uid }) else { return false }
            var flags = _mailboxes[i].messages[k].flags
            for f in add where !flags.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) { flags.append(f) }
            flags.removeAll { f in remove.contains { $0.caseInsensitiveCompare(f) == .orderedSame } }
            _mailboxes[i].modseq += 1
            _mailboxes[i].messages[k].flags = flags
            _mailboxes[i].messages[k].modseq = _mailboxes[i].modseq
            return true
        }
    }

    /// Copies `uids` from `source` to `dest`: (dest UIDVALIDITY, [(source uid, new uid)]).
    func copy(_ uids: [UInt32], from source: String, to dest: String) -> (UInt32, [(UInt32, UInt32)])? {
        lock.withLock {
            guard let s = _mailboxes.firstIndex(where: { $0.name == source }),
                  let d = _mailboxes.firstIndex(where: { $0.name == dest }) else { return nil }
            var pairs: [(UInt32, UInt32)] = []
            for m in _mailboxes[s].messages where uids.contains(m.uid) {
                let uid = _mailboxes[d].uidNext
                _mailboxes[d].uidNext += 1
                _mailboxes[d].modseq += 1
                var copy = m
                copy.uid = uid; copy.modseq = _mailboxes[d].modseq
                copy.flags.removeAll { $0.caseInsensitiveCompare("\\Deleted") == .orderedSame }
                _mailboxes[d].messages.append(copy)
                pairs.append((m.uid, uid))
            }
            return (_mailboxes[d].uidValidity, pairs)
        }
    }

    /// Removes messages carrying \Deleted (all of them, or only `only`).
    /// Returns the 1-based sequence numbers in the order to report them.
    func expungeDeleted(in name: String, only: Set<UInt32>? = nil, force: Set<UInt32> = []) -> [Int] {
        lock.withLock {
            guard let i = _mailboxes.firstIndex(where: { $0.name == name }) else { return [] }
            var reported: [Int] = []
            var index = _mailboxes[i].messages.count - 1
            while index >= 0 {
                let m = _mailboxes[i].messages[index]
                let deleted = m.flags.contains { $0.caseInsensitiveCompare("\\Deleted") == .orderedSame }
                if force.contains(m.uid) || (deleted && (only?.contains(m.uid) ?? true)) {
                    _mailboxes[i].messages.remove(at: index)
                    _mailboxes[i].modseq += 1
                    _mailboxes[i].expunged.append((m.uid, _mailboxes[i].modseq))
                    reported.append(index + 1)
                }
                index -= 1
            }
            return reported
        }
    }

    fileprivate func setSeen(_ uid: UInt32, in name: String) {
        lock.withLock {
            guard let i = _mailboxes.firstIndex(where: { $0.name == name }),
                  let k = _mailboxes[i].messages.firstIndex(where: { $0.uid == uid }) else { return }
            if !_mailboxes[i].messages[k].flags.contains("\\Seen") { _mailboxes[i].messages[k].flags.append("\\Seen") }
        }
    }
}

// MARK: - Server

final class LocalIMAPServer: @unchecked Sendable {
    let model: IMAPServerModel
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mailin.test.imapd")
    private let lock = NSLock()
    private var handlers: [ServerConnection] = []
    private(set) var port: UInt16 = 0

    init(model: IMAPServerModel = IMAPServerModel()) throws {
        self.model = model
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() async throws {
        let once = OnceFlag()
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let h = ServerConnection(conn, model: self.model, queue: self.queue)
            self.lock.withLock { self.handlers.append(h) }
            h.start()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() { self?.port = self?.listener.port?.rawValue ?? 0; c.resume() }
                case .failed(let e):
                    if once.fire() { c.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Sends `line` to every connection currently in IDLE.
    func pushToIdlers(_ line: String) {
        let hs = lock.withLock { handlers }
        for h in hs { h.pushIfIdling(line) }
    }

    func stop() {
        listener.cancel()
        let hs = lock.withLock { handlers }
        for h in hs { h.close() }
    }
}

private final class ServerConnection: @unchecked Sendable {
    let conn: NWConnection
    let model: IMAPServerModel
    let queue: DispatchQueue

    // All state below is touched on `queue` only.
    private var buffer: [UInt8] = []
    private var segments: [IMAPRawResponse.Segment] = []
    private var lineStart = 0
    private var ackedLiteral = false
    private var authenticated = false
    private var utf8 = false
    private var condstore = false
    private var qresync = false
    private var selected: String?
    private var readOnly = true
    private var saslPending: (tag: String, mechanism: String, failed: Bool)?
    private var idleTag: String?
    private var closed = false

    init(_ conn: NWConnection, model: IMAPServerModel, queue: DispatchQueue) {
        self.conn = conn; self.model = model; self.queue = queue
    }

    func start() {
        model.connected()
        conn.start(queue: queue)
        write(model.greeting + "\r\n")
        receive()
    }

    func close() { queue.async { self.closed = true; self.conn.cancel() } }

    func pushIfIdling(_ line: String) { queue.async { if self.idleTag != nil { self.write(line + "\r\n") } } }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer += data; self.process() }
            if done || error != nil { self.conn.cancel(); return }
            self.receive()
        }
    }

    private func write(_ s: String) { write(Data(s.utf8)) }

    private func write(_ d: Data) {
        guard !closed else { return }
        let chunk = model.writeChunk
        if chunk <= 0 || d.count <= chunk {
            conn.send(content: d, completion: .contentProcessed { _ in })
            return
        }
        var i = 0
        while i < d.count {
            let end = min(d.count, i + chunk)
            conn.send(content: d.subdata(in: i..<end), completion: .contentProcessed { _ in })
            i = end
        }
    }

    // MARK: Framing (client side: lines with literals)

    private func process() {
        while !closed {
            guard let lf = buffer[lineStart...].firstIndex(of: 0x0A) else { return }
            var line = Array(buffer[lineStart..<lf])
            if line.last == 0x0D { line.removeLast() }
            if let (n, sync) = Self.marker(&line) {
                if sync && !ackedLiteral { write("+ Ready for literal\r\n"); ackedLiteral = true }
                guard buffer.count >= lf + 1 + n else { return }
                segments.append(.text(line))
                segments.append(.literal(Array(buffer[(lf + 1)..<(lf + 1 + n)])))
                lineStart = lf + 1 + n
                ackedLiteral = false
                continue
            }
            segments.append(.text(line))
            let command = IMAPRawResponse(segments: segments)
            segments = []
            buffer.removeSubrange(0..<(lf + 1))
            lineStart = 0
            handle(command)
        }
    }

    private static func marker(_ line: inout [UInt8]) -> (Int, Bool)? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var inner = String(decoding: line[(open + 1)..<(line.count - 1)], as: UTF8.self)
        var sync = true
        if inner.hasSuffix("+") { inner.removeLast(); sync = false }
        guard let n = Int(inner) else { return nil }
        line.removeSubrange(open...)
        return (n, sync)
    }

    private static func text(_ r: IMAPRawResponse) -> String {
        r.segments.map { seg -> String in
            switch seg {
            case .text(let t): return String(decoding: t, as: UTF8.self)
            case .literal(let b): return "{\(b.count)}" + String(decoding: b, as: UTF8.self)
            case .streamed(let n): return "{\(n)}"
            }
        }.joined()
    }

    // MARK: Commands

    private func ok(_ tag: String, _ text: String) { write("\(tag) OK \(text)\r\n") }

    private func handle(_ command: IMAPRawResponse) {
        let line = Self.text(command)
        if let sasl = saslPending {
            model.record("<sasl> " + line)
            saslPending = nil
            if sasl.failed {
                write("\(sasl.tag) NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"); return
            }
            finishSASL(tag: sasl.tag, mechanism: sasl.mechanism, response: line)
            return
        }
        if let tag = idleTag {
            model.record(line)
            if line.uppercased() == "DONE" { idleTag = nil; ok(tag, "IDLE terminated") }
            return
        }
        model.record(line)
        model.onCommand?(line, model)
        var cursor = IMAPTokenCursor(command)
        let tag = cursor.word()
        let values = (try? cursor.values()) ?? []
        guard let verb = values.first?.atomText?.uppercased() else { write("\(tag) BAD no command\r\n"); return }
        let args = Array(values.dropFirst())

        switch verb {
        case "CAPABILITY":
            write("* CAPABILITY " + capabilities().joined(separator: " ") + "\r\n"); ok(tag, "CAPABILITY completed")
        case "NOOP": ok(tag, "NOOP completed")
        case "LOGOUT":
            write("* BYE logging out\r\n"); ok(tag, "LOGOUT completed")
            closed = true
            queue.asyncAfter(deadline: .now() + 0.05) { self.conn.cancel() }
        case "STARTTLS":
            if model.offerSTARTTLS && !authenticated { ok(tag, "Begin TLS negotiation now") } else { write("\(tag) BAD STARTTLS not offered\r\n") }
        case "LOGIN":
            let user = args.first?.text ?? "", pass = args.count > 1 ? args[1].text ?? "" : ""
            if !model.preAuthCapabilities.contains("LOGINDISABLED"), user == model.login, pass == model.password, model.authFailureCode == nil {
                authenticated = true; ok(tag, "[CAPABILITY \(capabilities().joined(separator: " "))] LOGIN completed")
            } else {
                write("\(tag) NO [\(model.authFailureCode ?? "AUTHENTICATIONFAILED")] Invalid credentials\r\n")
            }
        case "AUTHENTICATE":
            let mech = args.first?.atomText?.uppercased() ?? ""
            if args.count > 1, let ir = args[1].atomText {
                finishSASL(tag: tag, mechanism: mech, response: ir)
            } else {
                saslPending = (tag, mech, false); write("+ \r\n")
            }
        case "ENABLE":
            var enabled: [String] = []
            for a in args.compactMap(\.atomText) {
                let u = a.uppercased()
                if u == "UTF8=ACCEPT", has("UTF8=ACCEPT") { utf8 = true; enabled.append(a) }
                if u == "CONDSTORE", has("CONDSTORE") { condstore = true; enabled.append(a) }
                if u == "QRESYNC", has("QRESYNC") { qresync = true; condstore = true; enabled.append(a) }
            }
            write("* ENABLED " + enabled.joined(separator: " ") + "\r\n"); ok(tag, "ENABLE completed")
        case "NAMESPACE":
            write("* NAMESPACE ((\"\(model.namespacePrefix)\" \"\(model.delimiter)\")) NIL NIL\r\n"); ok(tag, "NAMESPACE completed")
        case "LIST":
            list(tag, args)
        case "EXAMINE", "SELECT":
            select(tag, args, readOnly: verb == "EXAMINE")
        case "UID":
            let sub = args.first?.atomText?.uppercased() ?? ""
            let rest = Array(args.dropFirst())
            if sub == "FETCH" {
                let delay = model.bodyDelay
                if delay > 0, Self.text(command).uppercased().contains("BODY") {
                    // Slow downloads: concurrent fetches overlap, so every pooled connection is used.
                    queue.asyncAfter(deadline: .now() + delay) { self.uidFetch(tag, rest) }
                } else {
                    uidFetch(tag, rest)
                }
            }
            else if sub == "SEARCH" { uidSearch(tag, rest) }
            else if model.serveServerActions, ["STORE", "COPY", "MOVE", "EXPUNGE"].contains(sub) { uidAction(tag, sub, rest) }
            else { write("\(tag) BAD UID \(sub) is not served by the test server\r\n") }
        case "EXPUNGE" where model.serveServerActions:
            // A mailbox-wide EXPUNGE: served like a real server (it removes
            // EVERY \Deleted message), so a test can prove mailin never sends it.
            guard let name = selected, !readOnly else { write("\(tag) NO not selected read-write\r\n"); return }
            for n in model.expungeDeleted(in: name) { write("* \(n) EXPUNGE\r\n") }
            ok(tag, "EXPUNGE completed")
        case "IDLE":
            guard has("IDLE") else { write("\(tag) BAD no IDLE\r\n"); return }
            idleTag = tag; write("+ idling\r\n")
        default:
            // FETCH, SEARCH, STORE, EXPUNGE, COPY, MOVE …: recorded in the
            // transcript (the read-only tests assert they never appear).
            write("\(tag) BAD \(verb) is not served by the test server\r\n")
        }
    }

    private func capabilities() -> [String] {
        var caps = authenticated ? model.postAuthCapabilities : model.preAuthCapabilities
        if !authenticated && model.offerSTARTTLS { caps.append("STARTTLS") }
        if model.oauthToken != nil && !authenticated { caps.append("AUTH=XOAUTH2") }
        return caps
    }

    private func has(_ c: String) -> Bool { model.postAuthCapabilities.contains(c) }

    private func finishSASL(tag: String, mechanism: String, response: String) {
        let decoded = Data(base64Encoded: response).map { [UInt8]($0) } ?? []
        var success = false
        switch mechanism {
        case "PLAIN":
            let parts = decoded.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            success = parts.count == 3 && parts[1] == model.login && parts[2] == model.password
        case "XOAUTH2":
            let s = String(decoding: decoded, as: UTF8.self)
            success = model.oauthToken != nil && s == "user=\(model.login)\u{1}auth=Bearer \(model.oauthToken!)\u{1}\u{1}"
            if !success {
                saslPending = (tag, mechanism, true)
                write("+ " + Data(#"{"status":"401","schemes":"bearer","scope":"https://mail.example/"}"#.utf8).base64EncodedString() + "\r\n")
                return
            }
        default:
            write("\(tag) NO [CANNOT] unsupported mechanism\r\n"); return
        }
        if success && model.authFailureCode == nil {
            authenticated = true
            ok(tag, "[CAPABILITY \(capabilities().joined(separator: " "))] AUTHENTICATE completed")
        } else {
            write("\(tag) NO [\(model.authFailureCode ?? "AUTHENTICATIONFAILED")] Invalid credentials\r\n")
        }
    }

    private func wireName(_ name: String) -> [UInt8] {
        if name == "INBOX" { return Array(name.utf8) }
        return utf8 ? Array(name.utf8) : Array(IMAPModifiedUTF7.encode(name).utf8)
    }

    private func decodeName(_ v: IMAPValue?) -> String? {
        guard let b = v?.bytes else { return nil }
        return IMAPMailboxName(wire: b, utf8: utf8).name
    }

    private func list(_ tag: String, _ args: [IMAPValue]) {
        guard authenticated else { write("\(tag) BAD not authenticated\r\n"); return }
        let pattern = args.count > 1 ? (decodeName(args[1]) ?? "*") : "*"
        for m in model.mailboxes {
            if pattern != "*" {
                let prefix = pattern.hasSuffix("*") ? String(pattern.dropLast()) : pattern
                guard m.name.hasPrefix(prefix) else { continue }
            }
            let wire = wireName(m.name)
            let attrs = "(" + m.attributes.joined(separator: " ") + ")"
            if model.namesAsLiterals {
                var d = Data("* LIST \(attrs) \"\(model.delimiter)\" {\(wire.count)}\r\n".utf8)
                d.append(contentsOf: wire); d.append(contentsOf: Array("\r\n".utf8))
                write(d)
            } else {
                var d = Data("* LIST \(attrs) \"\(model.delimiter)\" \"".utf8)
                for c in wire {
                    if c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\") { d.append(UInt8(ascii: "\\")) }
                    d.append(c)
                }
                d.append(contentsOf: Array("\"\r\n".utf8))
                write(d)
            }
        }
        ok(tag, "LIST completed")
    }

    private func select(_ tag: String, _ args: [IMAPValue], readOnly: Bool) {
        guard authenticated, let name = decodeName(args.first), let m = model.mailboxes.first(where: { $0.name == name }),
              !m.attributes.contains("\\Noselect") else {
            selected = nil
            write("\(tag) NO [NONEXISTENT] Unknown mailbox\r\n"); return
        }
        if args.count > 1, args[1].list?.first?.atomText?.uppercased() == "CONDSTORE" { condstore = true }
        selected = name
        self.readOnly = readOnly
        write("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n")
        write("* \(m.messages.count) EXISTS\r\n")
        write("* OK [UIDVALIDITY \(m.uidValidity)] UIDs valid\r\n")
        write("* OK [UIDNEXT \(m.uidNext)] Predicted next UID\r\n")
        if condstore { write("* OK [HIGHESTMODSEQ \(m.modseq)] Highest\r\n") }
        ok(tag, readOnly ? "[READ-ONLY] EXAMINE completed" : "[READ-WRITE] SELECT completed")
    }

    /// Sequence set over UIDs: "a:b", "a:*", "n", "a,b:c".
    private static func uids(_ set: String, existing: [UInt32]) -> Set<UInt32> {
        let maxUID = existing.max() ?? 0
        var out = Set<UInt32>()
        for part in set.split(separator: ",") {
            let ends = part.split(separator: ":").map { $0 == "*" ? maxUID : (UInt32($0) ?? 0) }
            let lo = min(ends[0], ends.count > 1 ? ends[1] : ends[0]), hi = max(ends[0], ends.count > 1 ? ends[1] : ends[0])
            for u in existing where u >= lo && u <= hi { out.insert(u) }
            // RFC 9051: "n:*" always includes the highest UID.
            if part.hasSuffix("*"), let last = existing.last { out.insert(last) }
        }
        return out
    }

    private func uidFetch(_ tag: String, _ args: [IMAPValue]) {
        guard let name = selected, let m = model.mailboxes.first(where: { $0.name == name }),
              let setText = args.first?.atomText else { write("\(tag) BAD no mailbox selected\r\n"); return }
        let items = (args.count > 1 ? (args[1].list ?? [args[1]]) : []).compactMap { $0.atomText?.uppercased() }
        var changedSince: UInt64?
        var vanished = false
        if args.count > 2, let mods = args[2].list {
            for (i, v) in mods.enumerated() {
                if v.atomText?.uppercased() == "CHANGEDSINCE", i + 1 < mods.count { changedSince = mods[i + 1].number }
                if v.atomText?.uppercased() == "VANISHED" { vanished = true }
            }
        }
        let wanted = Self.uids(setText, existing: m.messages.map(\.uid))
        if let since = changedSince, vanished, qresync {
            let gone = m.expunged.filter { $0.modseq > since }.map(\.uid)
            if !gone.isEmpty { write("* VANISHED (EARLIER) \(IMAPUIDSet(gone).sequenceSet)\r\n") }
        }
        for (index, msg) in m.messages.enumerated() where wanted.contains(msg.uid) {
            if let since = changedSince, msg.modseq <= since { continue }
            let wantsBody = items.contains("BODY.PEEK[]") || items.contains("BODY[]")
            if wantsBody, model.takeDrop(msg.uid) {
                // Drop mid-literal: half the bytes, then the connection ends.
                write(Data("* \(index + 1) FETCH (UID \(msg.uid) BODY[] {\(msg.bytes.count)}\r\n".utf8) + msg.bytes.prefix(msg.bytes.count / 2))
                closed = true
                queue.asyncAfter(deadline: .now() + 0.05) { self.conn.cancel() }
                return
            }
            if items.contains("BODY[]") && !readOnly { model.setSeen(msg.uid, in: name) }   // a real server marks it read
            var flags = model.flags(of: msg.uid, in: name) ?? msg.flags
            if items.contains("BODY[]") && readOnly == false && !flags.contains("\\Seen") { flags.append("\\Seen") }
            var parts: [String] = []
            if !model.uidAfterBody || !wantsBody { parts.append("UID \(msg.uid)") }
            if items.contains("RFC822.SIZE") { parts.append("RFC822.SIZE \(msg.bytes.count)") }
            if items.contains("FLAGS") { parts.append("FLAGS (" + flags.joined(separator: " ") + ")") }
            if items.contains("INTERNALDATE") { parts.append("INTERNALDATE \"\(msg.internalDate)\"") }
            if items.contains("MODSEQ") || changedSince != nil { parts.append("MODSEQ (\(msg.modseq))") }
            var d = Data("* \(index + 1) FETCH (".utf8)
            d.append(Data(parts.joined(separator: " ").utf8))
            if wantsBody {
                d.append(Data(((parts.isEmpty ? "" : " ") + "BODY[] {\(msg.bytes.count)}\r\n").utf8))
                d.append(msg.bytes)
                if model.uidAfterBody { d.append(Data(" UID \(msg.uid)".utf8)) }
            }
            d.append(Data(")\r\n".utf8))
            write(d)
        }
        ok(tag, "UID FETCH completed")
    }

    /// V4-11: UID STORE / COPY / MOVE / EXPUNGE on the selected mailbox.
    private func uidAction(_ tag: String, _ sub: String, _ args: [IMAPValue]) {
        guard let name = selected, let m = model.mailboxes.first(where: { $0.name == name }),
              let setText = args.first?.atomText else { write("\(tag) BAD no mailbox selected\r\n"); return }
        guard !readOnly else { write("\(tag) NO [READ-ONLY] the mailbox is read-only\r\n"); return }
        let wanted = Self.uids(setText, existing: m.messages.map(\.uid))
        let uidplus = has("UIDPLUS")
        switch sub {
        case "STORE":
            guard args.count >= 3, let item = args[1].atomText?.uppercased() else {
                write("\(tag) BAD STORE syntax\r\n"); return
            }
            let flags = (args[2].list ?? [args[2]]).compactMap(\.atomText)
            let silent = item.hasSuffix(".SILENT")
            for uid in wanted.sorted() {
                if item.hasPrefix("+") { _ = model.setFlags(uid, in: name, add: flags, remove: []) }
                else if item.hasPrefix("-") { _ = model.setFlags(uid, in: name, add: [], remove: flags) }
                if !silent, let f = model.flags(of: uid, in: name),
                   let seq = model.mailboxes.first(where: { $0.name == name })?.messages.firstIndex(where: { $0.uid == uid }) {
                    write("* \(seq + 1) FETCH (UID \(uid) FLAGS (\(f.joined(separator: " "))))\r\n")
                }
            }
            ok(tag, "STORE completed")
        case "COPY", "MOVE":
            if sub == "MOVE", !has("MOVE") { write("\(tag) BAD MOVE not offered\r\n"); return }
            guard args.count >= 2, let dest = decodeName(args[1]) else { write("\(tag) BAD \(sub) syntax\r\n"); return }
            guard let (validity, pairs) = model.copy(Array(wanted), from: name, to: dest) else {
                write("\(tag) NO [TRYCREATE] no such mailbox\r\n"); return
            }
            let code = uidplus && !pairs.isEmpty
                ? "[COPYUID \(validity) \(pairs.map { String($0.0) }.joined(separator: ",")) \(pairs.map { String($0.1) }.joined(separator: ","))] "
                : ""
            if sub == "COPY" { ok(tag, code + "COPY completed"); return }
            if !code.isEmpty { write("* OK \(code)moved\r\n") }
            for n in model.expungeDeleted(in: name, only: [], force: Set(pairs.map(\.0))) { write("* \(n) EXPUNGE\r\n") }
            ok(tag, "MOVE completed")
        case "EXPUNGE":
            guard uidplus else { write("\(tag) BAD UID EXPUNGE needs UIDPLUS\r\n"); return }
            for n in model.expungeDeleted(in: name, only: wanted) { write("* \(n) EXPUNGE\r\n") }
            ok(tag, "UID EXPUNGE completed")
        default:
            write("\(tag) BAD\r\n")
        }
    }

    private func uidSearch(_ tag: String, _ args: [IMAPValue]) {
        guard let name = selected, let m = model.mailboxes.first(where: { $0.name == name }) else {
            write("\(tag) BAD no mailbox selected\r\n"); return
        }
        var words = args.compactMap { $0.atomText?.uppercased() }
        let esearch = words.first == "RETURN"
        if esearch { words.removeFirst() }
        var result = m.messages.map(\.uid)
        if let i = words.firstIndex(of: "UID"), i + 1 < words.count {
            let set = Self.uids(words[i + 1], existing: result)
            result = result.filter { set.contains($0) }
        }
        if esearch {
            let set = IMAPUIDSet(result).sequenceSet
            write("* ESEARCH (TAG \"\(tag)\") UID" + (set.isEmpty ? "" : " ALL \(set)") + "\r\n")
        } else {
            write("* SEARCH" + result.map { " \($0)" }.joined() + "\r\n")
        }
        ok(tag, "UID SEARCH completed")
    }
}

// MARK: - Scripted byte stream

/// The server side is a closure from each complete client line to the exact
/// packets that come back. `upgradeToTLS` flips `isEncrypted` (the in-place
/// upgrade itself is Apple's; what is tested is what the session does around it).
final class ScriptedIMAPTransport: IMAPByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var pendingLine: [UInt8] = []
    private var encrypted: Bool
    private var isClosed = false
    private(set) var upgraded = false
    private(set) var sentLines: [String] = []
    private(set) var sentRaw = Data()
    var responder: (_ line: String, _ transport: ScriptedIMAPTransport) -> [Data]

    init(packets: [Data], encrypted: Bool = true,
         responder: @escaping (_ line: String, _ transport: ScriptedIMAPTransport) -> [Data] = { _, _ in [] }) {
        self.inbox = packets; self.encrypted = encrypted; self.responder = responder
    }

    var isEncrypted: Bool { lock.withLock { encrypted } }
    var lines: [String] { lock.withLock { sentLines } }

    func deliver(_ packets: [Data]) {
        lock.lock()
        inbox += packets
        if let w = waiter, !inbox.isEmpty { waiter = nil; let d = inbox.removeFirst(); lock.unlock(); w.resume(returning: d); return }
        lock.unlock()
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty { let d = inbox.removeFirst(); lock.unlock(); c.resume(returning: d); return }
            if isClosed { lock.unlock(); c.resume(returning: nil); return }
            waiter = c
            lock.unlock()
        }
    }

    func send(_ data: Data) async throws {
        var complete: [String] = []
        lock.withLock {
            sentRaw.append(data)
            for b in data {
                if b == 0x0A {
                    var l = pendingLine
                    if l.last == 0x0D { l.removeLast() }
                    let s = String(decoding: l, as: UTF8.self)
                    sentLines.append(s); complete.append(s); pendingLine = []
                } else { pendingLine.append(b) }
            }
        }
        for line in complete { deliver(responder(line, self)) }
    }

    func upgradeToTLS() async throws { lock.withLock { encrypted = true; upgraded = true } }

    func close() {
        lock.lock()
        isClosed = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
    }
}
