//
//  IMAPSession.swift
//  MailConnectivity
//
//  Plan v4 V4-07: one authenticated IMAP connection. Read-only by
//  construction: the commands it can send are CAPABILITY, STARTTLS,
//  AUTHENTICATE, LOGIN, ENABLE, NAMESPACE, LIST, EXAMINE, UID FETCH (with
//  BODY.PEEK[] only), UID SEARCH, IDLE/DONE, NOOP and LOGOUT. There is no
//  SELECT, STORE, COPY, MOVE, EXPUNGE, APPEND or non-UID FETCH/SEARCH here
//  (server actions are V4-11, in their own type).
//
//  Security, in order: the greeting is read; for STARTTLS the server must
//  offer it, the upgrade happens on the same connection and every pre-TLS
//  capability is discarded; NO credential is sent unless the channel is TLS
//  (or the configuration is the explicit loopback-only test/bridge mode).
//  Secrets are masked in the protocol log.
//

import Foundation

// MARK: - Capabilities

public struct IMAPCapabilities: Sendable, Equatable {
    public private(set) var atoms: Set<String> = []

    public init(_ words: [String] = []) { atoms = Set(words.map { $0.uppercased() }) }

    init(values: [IMAPValue]) { self.init(values.compactMap(\.atomText)) }

    init(codeArgument: String) { self.init(codeArgument.split(separator: " ").map(String.init)) }

    /// IMAP4rev2 folds several rev1 extensions into the base protocol.
    private static let rev2Implied: Set<String> = ["NAMESPACE", "ESEARCH", "LIST-EXTENDED", "SPECIAL-USE", "LITERAL-",
                                                    "ENABLE", "UNSELECT", "UIDPLUS", "IDLE", "SASL-IR", "MOVE", "STATUS=SIZE"]

    public func has(_ capability: String) -> Bool {
        let c = capability.uppercased()
        if atoms.contains(c) { return true }
        return atoms.contains("IMAP4REV2") && Self.rev2Implied.contains(c)
    }

    public var authMechanisms: Set<String> {
        Set(atoms.filter { $0.hasPrefix("AUTH=") }.map { String($0.dropFirst(5)) })
    }

    public var isEmpty: Bool { atoms.isEmpty }
}

// MARK: - Log

/// The client side of the conversation, secrets masked. For diagnostics and
/// tests; never contains a password or token.
public final class IMAPProtocolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    public init() {}
    func append(_ line: String) { lock.withLock { entries.append(line) } }
    public var lines: [String] { lock.withLock { entries } }
    public static let redacted = "<redacted>"
}

// MARK: - Arguments

enum IMAPArgument: Sendable {
    /// Protocol syntax sent as is (atoms, sequence sets, parenthesised lists).
    case raw(String)
    /// An astring: quoted when it can be, else a literal.
    case string([UInt8])
    /// As `.string`, masked in the log.
    case secret([UInt8])
    /// As `.raw`, masked in the log (a SASL initial response).
    case secretRaw(String)
}

// MARK: - Session

public enum IMAPAuthentication: Sendable {
    case password(login: String, password: String)
    case oauth(login: String, accessToken: String)
}

public struct IMAPMailboxStatus: Sendable, Equatable {
    public var uidValidity: UInt32
    public var uidNext: UInt32?
    public var highestModSeq: UInt64?
    public var exists: UInt64
    public var noModSeq: Bool
}

public struct IMAPListedMailbox: Sendable, Equatable {
    public var name: IMAPMailboxName
    public var delimiter: String?
    public var attributes: Set<String>       // uppercased, with the backslash
    public var isSelectable: Bool { !attributes.contains("\\NOSELECT") && !attributes.contains("\\NONEXISTENT") }
}

public struct IMAPNamespace: Sendable, Equatable {
    public var prefix: String
    public var delimiter: String?
}

public struct IMAPFetchedBody: Sendable {
    public var uid: UInt32
    public var byteCount: Int64
    public var flags: [String]
    public var internalDate: Date?
    public var modSeq: UInt64?
}

struct IMAPCommandResult: Sendable {
    var untagged: [IMAPResponse]
    var completion: IMAPStatusResponse
}

/// What a failed command was doing (decides the error mapping).
enum IMAPCommandContext: Sendable { case authenticate, examine, fetch, other }

public actor IMAPSession {
    let transport: any IMAPByteTransport
    let endpoint: IMAPEndpoint
    let log: IMAPProtocolLog
    private let framer = IMAPResponseFramer()
    private var queue: [IMAPResponse] = []
    private var tagCounter = 0
    private var busy = false
    public private(set) var capabilities = IMAPCapabilities()
    public private(set) var utf8Enabled = false
    public private(set) var qresyncEnabled = false
    public private(set) var condstoreEnabled = false
    public private(set) var personalNamespace: IMAPNamespace?
    public private(set) var otherNamespaces: [IMAPNamespace] = []
    public private(set) var isUsable = true
    private var selected: (wire: [UInt8], status: IMAPMailboxStatus)?

    init(transport: any IMAPByteTransport, endpoint: IMAPEndpoint, log: IMAPProtocolLog) {
        self.transport = transport; self.endpoint = endpoint; self.log = log
    }

    // MARK: Low level

    private func nextTag() -> String { tagCounter += 1; return "M\(tagCounter)" }

    private func fail() { isUsable = false; transport.close() }

    func nextResponse() async throws -> IMAPResponse {
        while queue.isEmpty {
            let data: Data?
            do { data = try await transport.receive() } catch { fail(); throw error }
            guard let data else { fail(); throw IMAPTransportError.closed }
            if data.isEmpty { continue }
            do {
                for raw in try framer.feed(data) { queue.append(try IMAPResponseParser.parse(raw)) }
            } catch {
                fail(); throw error
            }
        }
        let r = queue.removeFirst()
        if case .untaggedStatus(let s) = r, s.status == .bye { isUsable = false }
        return r
    }

    private func send(_ bytes: [UInt8]) async throws {
        do { try await transport.send(Data(bytes)) } catch { fail(); throw error }
    }

    private func canQuote(_ b: [UInt8]) -> Bool {
        guard b.count < 1_000 else { return false }
        for c in b {
            if c == 0x0D || c == 0x0A || c == 0 { return false }
            if c >= 0x80 && !utf8Enabled { return false }
        }
        return true
    }

    private func quoted(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "\"")]
        for c in b {
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\") { out.append(UInt8(ascii: "\\")) }
            out.append(c)
        }
        out.append(UInt8(ascii: "\""))
        return out
    }

    /// Sends one tagged command (literals included) and collects every
    /// response up to its completion. `onContinuation` answers "+" requests
    /// that are not literal go-aheads (SASL steps).
    func run(_ arguments: [IMAPArgument], context: IMAPCommandContext = .other,
             bodySink: IMAPLiteralSink? = nil,
             onContinuation: (@Sendable (String) -> [UInt8]?)? = nil) async throws -> IMAPCommandResult {
        guard isUsable else { throw IMAPTransportError.closed }
        guard !busy else { throw IMAPProtocolError.malformed("two commands on one connection at once") }
        busy = true
        defer { busy = false; framer.literalRouter = nil }
        let tag = nextTag()

        if let bodySink {
            framer.literalRouter = { preceding, _ in Self.isBodySection(preceding) ? bodySink : nil }
        }

        // Render: chunks separated by synchronising literals.
        var chunk: [UInt8] = Array(tag.utf8)
        var logLine = tag
        let nonSyncLimit = capabilities.has("LITERAL+") ? Int.max : (capabilities.has("LITERAL-") ? 4_096 : -1)
        for arg in arguments {
            chunk.append(0x20); logLine += " "
            switch arg {
            case .raw(let s):
                chunk += Array(s.utf8); logLine += s
            case .secretRaw(let s):
                chunk += Array(s.utf8); logLine += IMAPProtocolLog.redacted
            case .string(let b), .secret(let b):
                var secret = false
                if case .secret = arg { secret = true }
                if canQuote(b) {
                    chunk += quoted(b)
                    logLine += secret ? IMAPProtocolLog.redacted : String(decoding: quoted(b), as: UTF8.self)
                } else {
                    let sync = b.count > nonSyncLimit
                    chunk += Array("{\(b.count)\(sync ? "" : "+")}\r\n".utf8)
                    logLine += "{\(b.count)} " + (secret ? IMAPProtocolLog.redacted : String(decoding: b, as: UTF8.self))
                    if sync {
                        try await send(chunk); chunk = []
                        let r = try await nextResponse()
                        guard case .continuation = r else {
                            if case .tagged(_, let s) = r { throw Self.mapped(s, context: context) }
                            throw IMAPProtocolError.malformed("the server did not accept a literal")
                        }
                    }
                    chunk += b
                }
            }
        }
        chunk += [0x0D, 0x0A]
        log.append(logLine)
        try await send(chunk)

        var untagged: [IMAPResponse] = []
        while true {
            let r = try await nextResponse()
            switch r {
            case .tagged(let t, let status):
                guard t == tag else { fail(); throw IMAPProtocolError.malformed("a completion for another command (\(t))") }
                if let code = status.code, code.name == "CAPABILITY" { capabilities = IMAPCapabilities(codeArgument: code.argument) }
                return IMAPCommandResult(untagged: untagged, completion: status)
            case .continuation(let text):
                guard let onContinuation, let reply = onContinuation(text) else {
                    fail(); throw IMAPProtocolError.malformed("an unexpected continuation request")
                }
                log.append(IMAPProtocolLog.redacted)
                try await send(reply + [0x0D, 0x0A])
            case .data("CAPABILITY", let values):
                capabilities = IMAPCapabilities(values: values)
                untagged.append(r)
            case .untaggedStatus(let s) where s.status == .bye:
                untagged.append(r)          // the connection ends; the read after it fails as closed
            default:
                untagged.append(r)
            }
        }
    }

    /// A literal preceded by `BODY[]`, `BODY[]<n>` or `BINARY[]` is the message itself.
    nonisolated static func isBodySection(_ preceding: [UInt8]) -> Bool {
        var end = preceding.count
        while end > 0, preceding[end - 1] == 0x20 { end -= 1 }
        let tail = String(decoding: preceding[max(0, end - 32)..<end], as: UTF8.self).uppercased()
        if tail.hasSuffix("BODY[]") || tail.hasSuffix("BINARY[]") || tail.hasSuffix(" RFC822") || tail.hasSuffix("(RFC822") { return true }
        if let open = tail.range(of: "BODY[]<", options: .backwards) ?? tail.range(of: "BINARY[]<", options: .backwards) {
            let rest = tail[open.upperBound...]
            return rest.hasSuffix(">") && rest.dropLast().allSatisfy(\.isNumber)
        }
        return false
    }

    // MARK: Error mapping

    static func mapped(_ s: IMAPStatusResponse, context: IMAPCommandContext, oauth: Bool = false) -> MailProviderError {
        let code = s.code?.name ?? ""
        let text = s.text.isEmpty ? s.status.rawValue : s.text
        switch code {
        case "UNAVAILABLE", "INUSE", "SERVERBUG": return .transient("the mail server said: \(text)")
        case "OVERQUOTA": return .quotaExceeded(resetAfter: nil)
        case "LIMIT": return .rateLimited(retryAfter: nil)
        case "AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "EXPIRED":
            return oauth ? .unauthorized : .reauthorisationRequired
        case "PRIVACYREQUIRED": return .permanent("the mail server requires an encrypted connection: \(text)")
        case "NONEXISTENT": return context == .fetch ? .itemUnavailable : .folderUnavailable(text)
        case "EXPUNGEISSUED": return .itemUnavailable
        default: break
        }
        if s.status == .bad { return .permanent("the mail server rejected a command: \(text)") }
        switch context {
        case .authenticate: return oauth ? .unauthorized : .reauthorisationRequired
        case .examine: return .folderUnavailable(text)
        case .fetch, .other: return .transient("the mail server said: \(text)")
        }
    }

    @discardableResult
    func runOK(_ arguments: [IMAPArgument], context: IMAPCommandContext = .other,
               bodySink: IMAPLiteralSink? = nil) async throws -> IMAPCommandResult {
        let r = try await run(arguments, context: context, bodySink: bodySink)
        guard r.completion.status == .ok else { throw Self.mapped(r.completion, context: context) }
        return r
    }

    // MARK: Establish

    /// Greeting → (STARTTLS) → capabilities → authentication → ENABLE → NAMESPACE.
    func establish(_ auth: IMAPAuthentication) async throws {
        let greeting = try await nextResponse()
        var preauth = false
        switch greeting {
        case .untaggedStatus(let s) where s.status == .ok || s.status == .preauth:
            preauth = s.status == .preauth
            if let code = s.code, code.name == "CAPABILITY" { capabilities = IMAPCapabilities(codeArgument: code.argument) }
        case .untaggedStatus(let s) where s.status == .bye:
            fail(); throw MailProviderError.transient("the mail server refused the connection: \(s.text)")
        default:
            fail(); throw IMAPProtocolError.malformed("no greeting")
        }

        if endpoint.security == .startTLS {
            guard !preauth else {
                fail(); throw MailProviderError.permanent("the server pre-authenticated a connection that is not encrypted yet; mailin disconnected")
            }
            if capabilities.isEmpty { try await runOK([.raw("CAPABILITY")]) }
            guard capabilities.has("STARTTLS") else {
                fail()
                throw MailProviderError.permanent("\(endpoint.host) does not offer STARTTLS; mailin never sends a password without encryption")
            }
            try await runOK([.raw("STARTTLS")])
            // Anything already buffered after the OK was sent before TLS: an injection attempt.
            guard queue.isEmpty, framer.isIdle else {
                fail(); throw MailProviderError.permanent("the server sent data before the TLS handshake; mailin disconnected")
            }
            do { try await transport.upgradeToTLS() } catch { fail(); throw error }
            capabilities = IMAPCapabilities()                  // pre-TLS capabilities are not trusted
        }

        let mayAuthenticate = transport.isEncrypted || (endpoint.security == .plaintextLoopbackOnly && endpoint.isLoopback)
        guard mayAuthenticate else {
            fail(); throw MailProviderError.permanent("the connection to \(endpoint.host) is not encrypted; mailin never sends a password without encryption")
        }
        if capabilities.isEmpty { try await runOK([.raw("CAPABILITY")]) }

        if !preauth {
            let before = capabilities
            try await authenticate(auth)
            if capabilities == before { try await runOK([.raw("CAPABILITY")]) }
        }

        var enable: [String] = []
        if capabilities.has("UTF8=ACCEPT") { enable.append("UTF8=ACCEPT") }
        if capabilities.has("QRESYNC") { enable.append("QRESYNC") } else if capabilities.has("CONDSTORE") { enable.append("CONDSTORE") }
        if !enable.isEmpty, capabilities.has("ENABLE") {
            let r = try await run([.raw("ENABLE " + enable.joined(separator: " "))])
            if r.completion.status == .ok {
                for case .data("ENABLED", let values) in r.untagged {
                    for v in values.compactMap(\.atomText) {
                        switch v.uppercased() {
                        case "UTF8=ACCEPT": utf8Enabled = true
                        case "QRESYNC": qresyncEnabled = true; condstoreEnabled = true
                        case "CONDSTORE": condstoreEnabled = true
                        default: break
                        }
                    }
                }
            }
        }
        if !condstoreEnabled, capabilities.has("CONDSTORE") { condstoreEnabled = true }  // EXAMINE (CONDSTORE) enables it

        if capabilities.has("NAMESPACE") {
            let r = try await run([.raw("NAMESPACE")])
            for case .data("NAMESPACE", let values) in r.untagged {
                func parse(_ v: IMAPValue?) -> [IMAPNamespace] {
                    guard let list = v?.list else { return [] }
                    return list.compactMap { entry -> IMAPNamespace? in
                        guard let e = entry.list, let p = e.first?.bytes else { return nil }
                        let prefix = IMAPMailboxName(wire: p, utf8: utf8Enabled).name
                        return IMAPNamespace(prefix: prefix, delimiter: e.count > 1 ? e[1].text : nil)
                    }
                }
                personalNamespace = parse(values.first).first
                otherNamespaces = parse(values.count > 1 ? values[1] : nil) + parse(values.count > 2 ? values[2] : nil)
            }
        }
    }

    private func authenticate(_ auth: IMAPAuthentication) async throws {
        let mechanisms = capabilities.authMechanisms
        let saslIR = capabilities.has("SASL-IR")
        switch auth {
        case .password(let login, let password):
            if mechanisms.contains("PLAIN") {
                let blob = Array(Data(([0] + Array(login.utf8) + [0] + Array(password.utf8))).base64EncodedString().utf8)
                try await sasl("PLAIN", initial: blob, saslIR: saslIR, failureReply: nil, oauth: false)
            } else if !capabilities.has("LOGINDISABLED") {
                let r = try await run([.raw("LOGIN"), .string(Array(login.utf8)), .secret(Array(password.utf8))], context: .authenticate)
                guard r.completion.status == .ok else { throw Self.mapped(r.completion, context: .authenticate) }
            } else {
                throw MailProviderError.permanent("the mail server offers no password sign-in mailin supports")
            }
        case .oauth(let login, let token):
            if mechanisms.contains("OAUTHBEARER") {
                let gs2 = "n,a=\(login),\u{1}host=\(endpoint.host)\u{1}port=\(endpoint.port)\u{1}auth=Bearer \(token)\u{1}\u{1}"
                try await sasl("OAUTHBEARER", initial: Array(Data(gs2.utf8).base64EncodedString().utf8), saslIR: saslIR,
                               failureReply: Array("AQ==".utf8), oauth: true)
            } else if mechanisms.contains("XOAUTH2") {
                let s = "user=\(login)\u{1}auth=Bearer \(token)\u{1}\u{1}"
                try await sasl("XOAUTH2", initial: Array(Data(s.utf8).base64EncodedString().utf8), saslIR: saslIR,
                               failureReply: [], oauth: true)
            } else {
                throw MailProviderError.permanent("the mail server offers no OAuth sign-in (OAUTHBEARER or XOAUTH2)")
            }
        }
    }

    /// AUTHENTICATE with the initial response inline (SASL-IR) or after the
    /// first "+". A later "+" is the server's error challenge: answered with
    /// `failureReply` so the server can send its NO.
    private func sasl(_ mechanism: String, initial: [UInt8], saslIR: Bool, failureReply: [UInt8]?, oauth: Bool) async throws {
        let sent = SentFlag(initialSent: saslIR)
        var args: [IMAPArgument] = [.raw("AUTHENTICATE \(mechanism)")]
        if saslIR { args.append(.secretRaw(String(decoding: initial, as: UTF8.self))) }
        let r = try await run(args, context: .authenticate, onContinuation: { _ in
            if !sent.take() { return initial }
            return failureReply ?? Array("*".utf8)          // "*" cancels the exchange
        })
        guard r.completion.status == .ok else { throw Self.mapped(r.completion, context: .authenticate, oauth: oauth) }
    }

    // MARK: Mailboxes

    func mailboxArgument(_ wire: [UInt8]) -> IMAPArgument { .string(wire) }

    /// LIST of every mailbox under `reference` (all levels), SPECIAL-USE when offered.
    func list(pattern: String = "*") async throws -> [IMAPListedMailbox] {
        var args: [IMAPArgument] = [.raw("LIST"), .string([]), .string(Array(pattern.utf8))]
        if capabilities.has("LIST-EXTENDED") && capabilities.has("SPECIAL-USE") { args.append(.raw("RETURN (SPECIAL-USE)")) }
        let r = try await runOK(args)
        var out: [IMAPListedMailbox] = []
        for case .data("LIST", let values) in r.untagged {
            guard values.count >= 3, let attrs = values[0].list, let name = values[2].bytes else { continue }
            let delimiter: String? = values[1] == .nilValue ? nil : values[1].text
            out.append(IMAPListedMailbox(name: IMAPMailboxName(wire: name, utf8: utf8Enabled), delimiter: delimiter,
                                         attributes: Set(attrs.compactMap { $0.atomText?.uppercased() })))
        }
        return out
    }

    /// EXAMINE (read-only). `force` re-issues it even when already selected,
    /// to read the current UIDNEXT / HIGHESTMODSEQ.
    func examine(_ wire: [UInt8], force: Bool = false) async throws -> IMAPMailboxStatus {
        if !force, let selected, selected.wire == wire { return selected.status }
        selected = nil
        var args: [IMAPArgument] = [.raw("EXAMINE"), mailboxArgument(wire)]
        if condstoreEnabled && !qresyncEnabled { args.append(.raw("(CONDSTORE)")) }
        let r = try await runOK(args, context: .examine)
        if let code = r.completion.code, code.name == "READ-WRITE" {
            // Never happens on a conforming server; a read-write selection could set \Seen.
            fail(); throw MailProviderError.permanent("the server opened a folder read-write for a read-only request")
        }
        var validity: UInt32?, next: UInt32?, modseq: UInt64?, exists: UInt64 = 0, noModSeq = false
        for u in r.untagged {
            switch u {
            case .untaggedStatus(let s):
                guard let code = s.code else { continue }
                switch code.name {
                case "UIDVALIDITY": validity = code.number.flatMap { UInt32(exactly: $0) }
                case "UIDNEXT": next = code.number.flatMap { UInt32(exactly: $0) }
                case "HIGHESTMODSEQ": modseq = code.number
                case "NOMODSEQ": noModSeq = true
                default: break
                }
            case .numbered(let n, "EXISTS"): exists = n
            default: break
            }
        }
        guard let validity, validity != 0 else {
            throw MailProviderError.permanent("the server reported no UIDVALIDITY for this folder; its messages cannot be identified safely")
        }
        let status = IMAPMailboxStatus(uidValidity: validity, uidNext: next, highestModSeq: noModSeq ? nil : modseq,
                                       exists: exists, noModSeq: noModSeq)
        selected = (wire, status)
        return status
    }

    // MARK: Messages (UID only)

    /// `UID FETCH set (UID RFC822.SIZE)`: identities and sizes, never bodies.
    func uidSizes(_ set: String) async throws -> [(uid: UInt32, size: Int64?)] {
        let r = try await runOK([.raw("UID FETCH \(set) (UID RFC822.SIZE)")], context: .fetch)
        var out: [(UInt32, Int64?)] = []
        for case .fetch(_, let items) in r.untagged {
            guard let uid = items.first(where: { $0.name == "UID" })?.value.number.flatMap({ UInt32(exactly: $0) }) else { continue }
            let size = items.first(where: { $0.name == "RFC822.SIZE" })?.value.number.flatMap { Int64(exactly: $0) }
            out.append((uid, size))
        }
        return out.map { (uid: $0.0, size: $0.1) }
    }

    /// Every UID in the selected mailbox (ESEARCH when offered: compact ranges).
    func searchAllUIDs() async throws -> IMAPUIDSet {
        let esearch = capabilities.has("ESEARCH")
        let r = try await runOK([.raw(esearch ? "UID SEARCH RETURN (ALL) ALL" : "UID SEARCH ALL")])
        var set = IMAPUIDSet()
        for u in r.untagged {
            switch u {
            case .data("SEARCH", let values):
                for n in values.compactMap({ $0.number.flatMap { UInt32(exactly: $0) } }) { set.insert(n) }
            case .data("ESEARCH", let values):
                var k = 0
                while k < values.count {
                    if values[k].atomText?.uppercased() == "ALL", k + 1 < values.count, let s = values[k + 1].atomText,
                       let parsed = IMAPUIDSet(sequenceSet: s) {
                        for range in parsed.ranges { set.insert(range) }
                        k += 2
                    } else { k += 1 }
                }
            default: break
            }
        }
        return set
    }

    /// CONDSTORE / QRESYNC: UIDs changed after `modSeq`, and (QRESYNC) UIDs expunged since.
    func changedSince(_ modSeq: UInt64) async throws -> (changed: [UInt32], vanished: IMAPUIDSet) {
        let modifier = qresyncEnabled ? "(CHANGEDSINCE \(modSeq) VANISHED)" : "(CHANGEDSINCE \(modSeq))"
        let r = try await runOK([.raw("UID FETCH 1:* (UID) \(modifier)")], context: .fetch)
        var changed: [UInt32] = []
        var vanished = IMAPUIDSet()
        for u in r.untagged {
            switch u {
            case .fetch(_, let items):
                if let uid = items.first(where: { $0.name == "UID" })?.value.number.flatMap({ UInt32(exactly: $0) }) { changed.append(uid) }
            case .data("VANISHED", let values):
                if let s = values.last?.atomText, let parsed = IMAPUIDSet(sequenceSet: s) {
                    for range in parsed.ranges { vanished.insert(range) }
                }
            default: break
            }
        }
        return (changed, vanished)
    }

    /// Streams the complete message `uid` (BODY.PEEK[] — \Seen is never set)
    /// into `sink`. nil = the server has no such UID (expunged).
    func fetchBody(uid: UInt32, into sink: @escaping IMAPLiteralSink) async throws -> IMAPFetchedBody? {
        var items = "UID RFC822.SIZE FLAGS INTERNALDATE"
        if condstoreEnabled { items += " MODSEQ" }
        items += " BODY.PEEK[]"
        let r = try await runOK([.raw("UID FETCH \(uid) (\(items))")], context: .fetch, bodySink: sink)
        var found: IMAPFetchedBody?
        for case .fetch(_, let attrs) in r.untagged {
            guard let u = attrs.first(where: { $0.name == "UID" })?.value.number.flatMap({ UInt32(exactly: $0) }) else { continue }
            let body = attrs.first(where: { $0.name.hasPrefix("BODY[]") || $0.name.hasPrefix("BINARY[]") || $0.name == "RFC822" })
            guard let body else { continue }            // an unsolicited flag update
            guard u == uid else {
                throw MailProviderError.permanent("the server sent the body of UID \(u) for a request of UID \(uid)")
            }
            guard case .streamed(let n) = body.value else {
                if body.value == .nilValue { throw MailProviderError.itemUnavailable }
                throw MailProviderError.permanent("the server did not send the message as a literal")
            }
            let flags = attrs.first(where: { $0.name == "FLAGS" })?.value.list?.compactMap(\.atomText) ?? []
            let date = attrs.first(where: { $0.name == "INTERNALDATE" })?.value.text.flatMap(Self.parseInternalDate)
            let modseq = attrs.first(where: { $0.name == "MODSEQ" })?.value.list?.first?.number
            found = IMAPFetchedBody(uid: u, byteCount: n, flags: flags, internalDate: date, modSeq: modseq)
        }
        return found
    }

    /// "17-Jul-1996 02:44:25 -0700"
    nonisolated static func parseInternalDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    // MARK: IDLE

    /// Waits up to `timeout` for the selected mailbox to change (RFC 2177).
    /// Returns true when the server reported a change; false on timeout.
    func idle(timeout: TimeInterval) async throws -> Bool {
        guard capabilities.has("IDLE") else { return false }
        guard isUsable, !busy else { throw IMAPTransportError.closed }
        busy = true
        defer { busy = false }
        let tag = nextTag()
        log.append("\(tag) IDLE")
        try await send(Array("\(tag) IDLE\r\n".utf8))
        guard case .continuation = try await nextResponse() else {
            fail(); throw IMAPProtocolError.malformed("IDLE was not accepted")
        }
        let done = OnceFlag()
        let transport = self.transport
        let log = self.log
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            if done.fire() { log.append("DONE"); try? await transport.send(Data("DONE\r\n".utf8)) }
        }
        defer { timer.cancel() }
        var changed = false
        while true {
            let r = try await nextResponse()
            switch r {
            case .numbered(_, "EXISTS"), .numbered(_, "EXPUNGE"), .fetch, .data("VANISHED", _):
                changed = true
                if done.fire() { log.append("DONE"); try await send(Array("DONE\r\n".utf8)) }
            case .tagged(let t, _) where t == tag:
                selected = nil          // counts may have moved: re-EXAMINE next time
                return changed
            default:
                continue
            }
        }
    }

    func logout() async {
        guard isUsable, !busy else { transport.close(); return }
        _ = try? await run([.raw("LOGOUT")])
        isUsable = false
        transport.close()
    }
}

/// First continuation sends the initial response, later ones the failure reply.
final class SentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Bool
    init(initialSent: Bool) { sent = initialSent }
    func take() -> Bool { lock.withLock { let was = sent; sent = true; return was } }
}
