//
//  SMTPSubmitter.swift
//  MailConnectivity
//
//  Plan v4 V4-10 (§3 A11/A12, §6): hardened SMTP submission (RFC 5321,
//  RFC 3207 STARTTLS, RFC 4954 AUTH, RFC 6152 8BITMIME, RFC 6531 SMTPUTF8,
//  RFC 1870 SIZE). Written from the RFCs; it shares nothing with the old
//  `maxmailin/SMTPClient.swift`.
//
//   • Replies: multi-line (`250-` … `250 `) assembled across any read
//     boundary; mixed codes or a non-numeric reply are a protocol error.
//   • Deadlines per step (RFC 5321 §4.5.3.2: 5 minutes per command,
//     10 minutes for the reply to the final dot) and task cancellation.
//   • TLS is required before credentials: STARTTLS upgrades the same
//     connection; no STARTTLS offered, a refused STARTTLS, bytes pipelined
//     after the 220, or a failed handshake (bad certificate / host name)
//     ends the session — the secret is never even read from the Keychain.
//   • AUTH PLAIN / LOGIN for passwords, XOAUTH2 for OAuth tokens (one
//     refresh after a 535, on the same connection).
//   • 8BITMIME / SMTPUTF8 / SIZE decided from the post-TLS EHLO before MAIL.
//   • DATA: dot transparency (RFC 5321 §4.5.2), CRLF line endings; the
//     message bytes are sent unchanged otherwise.
//   • One submission per call. A failure after the final dot may have been
//     accepted → `.uncertain`; a QUIT failure after 250 is ignored.
//

import Foundation

public struct SMTPServerSettings: Sendable, Equatable {
    public enum Security: String, Sendable, Codable {
        /// Port 587: plaintext greeting, then STARTTLS on the same connection (required).
        case startTLS
        /// Port 465: TLS from the first byte.
        case implicitTLS
    }

    public var host: String
    public var port: Int
    public var security: Security
    /// The EHLO argument (RFC 5321 §4.1.4: a domain or an address literal).
    public var clientName: String
    public var connectTimeout: TimeInterval
    public var commandTimeout: TimeInterval
    public var dataTerminationTimeout: TimeInterval
    /// Where an OAuth refresh goes (for the network permission).
    public var authorizationHost: String?

    public init(host: String, port: Int = 587, security: Security = .startTLS, clientName: String = "[127.0.0.1]",
                connectTimeout: TimeInterval = 60, commandTimeout: TimeInterval = 300, dataTerminationTimeout: TimeInterval = 600,
                authorizationHost: String? = nil) {
        self.host = host; self.port = port; self.security = security; self.clientName = clientName
        self.connectTimeout = connectTimeout; self.commandTimeout = commandTimeout
        self.dataTerminationTimeout = dataTerminationTimeout; self.authorizationHost = authorizationHost
    }
}

/// Where the secret comes from — read only once TLS is up.
public enum SMTPCredentialSource: Sendable {
    /// Password or app password in the account-scoped `CredentialStore` (`.password`).
    case password(username: String, store: any CredentialStore)
    /// OAuth access token for `audience` (Gmail / Outlook SMTP).
    case oauth2(username: String, tokens: any AccessTokenSource, audience: String)
}

/// One server reply (possibly multi-line).
public struct SMTPReply: Sendable, Equatable {
    public var code: Int
    public var lines: [String]
    public var text: String { lines.joined(separator: "\n") }
    /// RFC 3463 enhanced status (`5.4.5`) from the first line, when present.
    public var enhanced: String? {
        guard let first = lines.first else { return nil }
        let token = first.split(separator: " ").first.map(String.init) ?? ""
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return token
    }
    public var isPositive: Bool { (200..<400).contains(code) }
    var summary: String { "\(code) \(lines.first ?? "")" }
}

enum SMTPFailure: Error {
    case timeout(String)
    case closed(String)
    case io(String)
    case protocolViolation(String)
    case cancelled
    case stopBeforeFinalStep(String)
    /// The TLS handshake failed (port 465 at the first read, or after
    /// STARTTLS): `certificate` = the server's certificate was refused.
    case tls(String, certificate: Bool)

    /// `.io` unless `error` is a TLS failure.
    static func io(_ stage: String, _ error: Error) -> SMTPFailure {
        if let c = MailTLSFailure.classify(error) { return .tls("\(stage): \(error.localizedDescription)", certificate: c.certificate) }
        return .io("\(stage): \(error.localizedDescription)")
    }
}

/// Reads and writes SMTP lines over one stream (used by one task at a time).
final class SMTPWire: @unchecked Sendable {
    static let maximumReplyLine = 64 * 1024   // protocol safety bound (RFC 5321 says 512)
    let stream: any SMTPByteStream
    var buffer = Data()

    init(_ stream: any SMTPByteStream) { self.stream = stream }

    func write(_ data: Data, timeout: TimeInterval, stage: String) async throws {
        let stream = self.stream
        do {
            try await withSMTPDeadline(timeout, onTimeout: { stream.close() }) { try await stream.write(data) }
        } catch is SMTPDeadlineExceeded {
            throw SMTPFailure.timeout(stage)
        } catch is CancellationError {
            throw SMTPFailure.cancelled
        } catch {
            if Task.isCancelled { throw SMTPFailure.cancelled }
            throw SMTPFailure.io(stage, error)
        }
    }

    /// One command line; CR / LF inside it would smuggle a second command.
    func command(_ line: String, timeout: TimeInterval, stage: String) async throws {
        guard !line.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw SMTPFailure.protocolViolation("a command contained a line break")
        }
        try await write(Data((line + "\r\n").utf8), timeout: timeout, stage: stage)
    }

    func reply(timeout: TimeInterval, stage: String) async throws -> SMTPReply {
        var lines: [String] = []
        var code: Int?
        while true {
            let line = try await nextLine(timeout: timeout, stage: stage)
            let scalars = Array(line.utf8)
            guard scalars.count >= 3, scalars[0...2].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = Int(String(decoding: scalars[0...2], as: UTF8.self)) else {
                throw SMTPFailure.protocolViolation("\(stage): the server's reply was not an SMTP reply")
            }
            if let code, code != value { throw SMTPFailure.protocolViolation("\(stage): a multi-line reply changed its code") }
            code = value
            let separator: UInt8? = scalars.count > 3 ? scalars[3] : nil
            guard separator == nil || separator == 0x20 || separator == 0x2D else {
                throw SMTPFailure.protocolViolation("\(stage): malformed reply line")
            }
            lines.append(scalars.count > 4 ? String(decoding: scalars[4...], as: UTF8.self) : "")
            if separator != 0x2D { return SMTPReply(code: value, lines: lines) }
        }
    }

    private func nextLine(timeout: TimeInterval, stage: String) async throws -> String {
        while true {
            if let lf = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<lf]
                if line.last == 0x0D { line = line.dropLast() }
                buffer = Data(buffer[(lf + 1)...])
                return String(decoding: line, as: UTF8.self)
            }
            guard buffer.count <= Self.maximumReplyLine else { throw SMTPFailure.protocolViolation("\(stage): reply line too long") }
            let stream = self.stream
            let piece: Data
            do {
                piece = try await withSMTPDeadline(timeout, onTimeout: { stream.close() }) { try await stream.read() }
            } catch is SMTPDeadlineExceeded {
                throw SMTPFailure.timeout(stage)
            } catch is CancellationError {
                throw SMTPFailure.cancelled
            } catch {
                if Task.isCancelled { throw SMTPFailure.cancelled }
                throw SMTPFailure.io(stage, error)
            }
            if piece.isEmpty { throw SMTPFailure.closed(stage) }
            buffer.append(piece)
        }
    }
}

public struct SMTPSubmitter: MessageSubmitter {
    public let settings: SMTPServerSettings
    let credentials: SMTPCredentialSource
    let connector: any SMTPConnector
    let permission: NetworkPermission

    public init(settings: SMTPServerSettings, credentials: SMTPCredentialSource, connector: any SMTPConnector = URLSessionSMTPConnector(),
                permission: @escaping NetworkPermission) {
        self.settings = settings; self.credentials = credentials; self.connector = connector; self.permission = permission
    }

    /// RFC 5321 §4.5.2: a line starting with "." gets one more; the payload ends with CRLF, then ".\r\n" follows.
    public static func dotStuffed(_ message: Data) -> Data {
        var out = Data(capacity: message.count + message.count / 64 + 8)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if atLineStart && byte == 0x2E { out.append(0x2E) }
            out.append(byte)
            atLineStart = previous == 0x0D && byte == 0x0A
            previous = byte
        }
        if !(out.count >= 2 && out[out.count - 2] == 0x0D && out[out.count - 1] == 0x0A) { out.append(contentsOf: [0x0D, 0x0A]) }
        return out
    }

    public func submit(_ message: OutboundMessage, checkpoint: @escaping SubmissionCheckpoint) async -> SubmissionOutcome {
        if Task.isCancelled { return .retry(reason: "sending was stopped before it began", after: 0, quota: false, automatic: true) }
        do {
            try permission(NetworkAsk(accountID: message.accountID, host: settings.host, destination: .mailServer, operation: .request))
        } catch {
            return .retry(reason: "connecting to \(settings.host) is not permitted: \(error.localizedDescription)", after: nil, quota: false, automatic: false)
        }
        let stream: any SMTPByteStream
        do {
            let connector = self.connector, host = settings.host, port = settings.port, implicit = settings.security == .implicitTLS
            stream = try await withSMTPDeadline(settings.connectTimeout, onTimeout: {}) {
                try await connector.connect(host: host, port: port, implicitTLS: implicit)
            }
        } catch {
            if case .tls = SMTPFailure.io("connect", error) {
                return .retry(reason: tlsReason(SMTPFailure.io("connect", error)), after: nil, quota: false, automatic: false)
            }
            return .retry(reason: "could not connect to \(settings.host): \(error.localizedDescription)", after: nil, quota: false, automatic: true)
        }
        let wire = SMTPWire(stream)
        defer { stream.close() }
        var finalDotWritten = false
        do {
            return try await session(wire, message, checkpoint: checkpoint, finalDotWritten: &finalDotWritten)
        } catch let failure as SMTPFailure {
            if finalDotWritten {
                return .uncertain(reason: Self.describe(failure) + " — after the whole message was sent, before the server's reply")
            }
            switch failure {
            case .stopBeforeFinalStep(let why):
                return .retry(reason: why, after: 0, quota: false, automatic: true)
            case .protocolViolation(let why):
                return .retry(reason: "the server did not follow the mail protocol: \(why)", after: nil, quota: false, automatic: false)
            case .tls:
                // Retrying cannot make a certificate trusted: the user decides.
                return .retry(reason: tlsReason(failure), after: nil, quota: false, automatic: false)
            default:
                return .retry(reason: Self.describe(failure), after: nil, quota: false, automatic: true)
            }
        } catch {
            return finalDotWritten ? .uncertain(reason: error.localizedDescription)
                                   : .retry(reason: error.localizedDescription, after: nil, quota: false, automatic: true)
        }
    }

    static func describe(_ f: SMTPFailure) -> String {
        switch f {
        case .timeout(let stage): return "the server did not answer in time (\(stage))"
        case .closed(let stage): return "the server closed the connection (\(stage))"
        case .io(let why): return "the connection failed (\(why))"
        case .protocolViolation(let why): return "protocol error (\(why))"
        case .cancelled: return "sending was stopped"
        case .stopBeforeFinalStep(let why): return why
        case .tls(let why, let certificate):
            return certificate ? "the server's certificate is not trusted (\(why))" : "the secure connection failed (\(why))"
        }
    }

    /// "<code>: …" for a TLS failure (`IMAPErrorCode.smtpCertificateNotTrusted`
    /// / `.smtpTLSHandshakeFailed`); credentials are never sent before TLS.
    func tlsReason(_ f: SMTPFailure) -> String {
        guard case .tls(let why, let certificate) = f else { return Self.describe(f) }
        let text = certificate
            ? "the certificate of \(settings.host) is not trusted (\(why)). Your sign-in details were not sent."
            : "a secure connection to \(settings.host) could not be established (\(why)). Your sign-in details were not sent."
        return IMAPErrorCode.coded(certificate ? IMAPErrorCode.smtpCertificateNotTrusted : IMAPErrorCode.smtpTLSHandshakeFailed, text)
    }

    /// Ends the session politely after a refusal; errors are irrelevant now.
    private func quit(_ wire: SMTPWire) async {
        try? await wire.command("QUIT", timeout: 5, stage: "QUIT")
        _ = try? await wire.reply(timeout: 5, stage: "QUIT")
    }

    private func notSecure(_ wire: SMTPWire, _ why: String) async -> SubmissionOutcome {
        await quit(wire)
        return .retry(reason: "\(why). Your sign-in details were not sent.", after: nil, quota: false, automatic: false)
    }

    private func session(_ wire: SMTPWire, _ message: OutboundMessage, checkpoint: SubmissionCheckpoint,
                         finalDotWritten: inout Bool) async throws -> SubmissionOutcome {
        let t = settings.commandTimeout
        let greeting = try await wire.reply(timeout: t, stage: "greeting")
        guard greeting.code == 220 else {
            return .retry(reason: "the server refused the connection: \(greeting.summary)", after: nil, quota: false, automatic: true)
        }
        var capabilities = try await ehlo(wire)
        guard let ehloReply = capabilities else {
            await quit(wire)
            return .retry(reason: "the server did not accept EHLO", after: nil, quota: false, automatic: false)
        }
        var caps = ehloReply

        if !wire.stream.isTLS {
            guard settings.security == .startTLS else { return await notSecure(wire, "The connection is not encrypted") }
            guard caps.keys.contains("STARTTLS") else {
                return await notSecure(wire, "\(settings.host) did not offer a secure connection (STARTTLS)")
            }
            try await wire.command("STARTTLS", timeout: t, stage: "STARTTLS")
            let ready = try await wire.reply(timeout: t, stage: "STARTTLS")
            guard ready.code == 220 else { return await notSecure(wire, "\(settings.host) refused to start a secure connection (\(ready.summary))") }
            // Bytes already received after the 220 were sent in plaintext and
            // would be read as if protected (command injection): refuse.
            guard wire.buffer.isEmpty else {
                return .retry(reason: "The server sent unexpected data before encryption began. Your sign-in details were not sent.",
                              after: nil, quota: false, automatic: false)
            }
            do { try await wire.stream.startTLS() } catch {
                if case .tls = SMTPFailure.io("STARTTLS", error) {
                    return .retry(reason: tlsReason(SMTPFailure.io("STARTTLS", error)), after: nil, quota: false, automatic: false)
                }
                return .retry(reason: "A secure connection to \(settings.host) could not be established (\(error.localizedDescription)). Your sign-in details were not sent.",
                              after: nil, quota: false, automatic: false)
            }
            // Capabilities from before TLS are discarded (RFC 3207 §4.2).
            do { capabilities = try await ehlo(wire) } catch let f as SMTPFailure {
                if case .tls = f { return .retry(reason: tlsReason(f), after: nil, quota: false, automatic: false) }
                return .retry(reason: "A secure connection to \(settings.host) could not be established — the certificate may not be valid for this server (\(Self.describe(f))). Your sign-in details were not sent.",
                              after: nil, quota: false, automatic: false)
            }
            guard let secured = capabilities else { return await notSecure(wire, "The server did not accept EHLO after encryption began") }
            caps = secured
        }
        guard wire.stream.isTLS else { return await notSecure(wire, "The connection is not encrypted") }

        if let refused = try await authenticate(wire, caps: caps, accountID: message.accountID) { return refused }

        // Capability decisions, before anything of the message is sent.
        let eightBit = message.bytes.contains { $0 >= 0x80 }
        if message.requiresSMTPUTF8 && !caps.keys.contains("SMTPUTF8") {
            await quit(wire)
            return .rejected(reason: "\(settings.host) cannot send messages with international (non-ASCII) addresses", rejectedRecipients: [])
        }
        if eightBit && !caps.keys.contains("8BITMIME") {
            await quit(wire)
            return .rejected(reason: "\(settings.host) cannot carry 8-bit message content", rejectedRecipients: [])
        }
        let size = message.bytes.count
        if let limit = caps["SIZE"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), limit > 0, size > limit {
            await quit(wire)
            return .rejected(reason: "the message (\(size) bytes as sent) is larger than \(settings.host)'s limit of \(limit) bytes", rejectedRecipients: [])
        }

        var mail = "MAIL FROM:<\(message.envelopeFrom)>"
        if caps.keys.contains("SIZE") { mail += " SIZE=\(size)" }
        if eightBit { mail += " BODY=8BITMIME" }
        if message.requiresSMTPUTF8 { mail += " SMTPUTF8" }
        try await wire.command(mail, timeout: t, stage: "MAIL FROM")
        let mailReply = try await wire.reply(timeout: t, stage: "MAIL FROM")
        if !mailReply.isPositive {
            await quit(wire)
            return Self.classify(mailReply, stage: "the sender")
        }

        var rejected: [String] = []
        var reasons: [String] = []
        for recipient in message.envelopeRecipients {
            try await wire.command("RCPT TO:<\(recipient)>", timeout: t, stage: "RCPT TO")
            let r = try await wire.reply(timeout: t, stage: "RCPT TO")
            if r.isPositive { continue }
            if r.code >= 500 && !Self.isQuota(r) {
                rejected.append(recipient); reasons.append("\(recipient): \(r.summary)")
                continue
            }
            await quit(wire)
            return Self.classify(r, stage: "a recipient")
        }
        if !rejected.isEmpty {
            // No partial send: the user decides what to do with the refused addresses.
            await quit(wire)
            return .rejected(reason: "the server refused \(rejected.count) of \(message.envelopeRecipients.count) recipients (" + reasons.joined(separator: "; ") + ")",
                             rejectedRecipients: rejected)
        }

        try await wire.command("DATA", timeout: t, stage: "DATA")
        let go = try await wire.reply(timeout: t, stage: "DATA")
        guard go.code == 354 else {
            await quit(wire)
            return Self.classify(go, stage: "the message")
        }
        try await wire.write(Self.dotStuffed(message.bytes), timeout: t, stage: "message")
        // Until the final dot the server discards an incomplete message: stop
        // here if the outbox cannot durably record "may have been sent".
        if Task.isCancelled { throw SMTPFailure.stopBeforeFinalStep("sending was stopped before the message was complete") }
        do { try await checkpoint(.mayHaveReachedProvider) } catch {
            throw SMTPFailure.stopBeforeFinalStep("the outbox could not record the send (\(error.localizedDescription)); the message was not completed")
        }
        finalDotWritten = true
        try await wire.write(Data(".\r\n".utf8), timeout: t, stage: "end of message")
        let final = try await wire.reply(timeout: settings.dataTerminationTimeout, stage: "end of message")
        guard final.code == 250 else {
            await quit(wire)
            finalDotWritten = false    // a definite refusal is not uncertain
            return Self.classify(final, stage: "the message")
        }
        // Accepted. QUIT is a courtesy: its failure cannot undo acceptance.
        await quit(wire)
        return .accepted(response: final.summary, providerReference: nil, savedToSent: false)
    }

    /// nil = EHLO refused. Keys are upper-cased keywords; values the rest of the line.
    private func ehlo(_ wire: SMTPWire) async throws -> [String: String]? {
        try await wire.command("EHLO \(settings.clientName)", timeout: settings.commandTimeout, stage: "EHLO")
        let r = try await wire.reply(timeout: settings.commandTimeout, stage: "EHLO")
        guard r.code == 250 else { return nil }
        var caps: [String: String] = [:]
        for line in r.lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first?.uppercased(), !key.isEmpty else { continue }
            caps[key] = parts.count > 1 ? parts[1] : ""
        }
        return caps
    }

    /// nil = authenticated; otherwise the outcome to return.
    private func authenticate(_ wire: SMTPWire, caps: [String: String], accountID: UUID) async throws -> SubmissionOutcome? {
        let mechanisms = Set((caps["AUTH"] ?? "").uppercased().split(separator: " ").map(String.init))
        let t = settings.commandTimeout
        switch credentials {
        case .password(let username, let store):
            let mechanism = mechanisms.contains("PLAIN") ? "PLAIN" : (mechanisms.contains("LOGIN") ? "LOGIN" : nil)
            guard let mechanism else {
                await quit(wire)
                return .needsSignIn(reason: "\(settings.host) offers no password sign-in method mailin supports (PLAIN, LOGIN)")
            }
            let secretData: Data?
            do { secretData = try store.read(.password, account: accountID) } catch {
                await quit(wire)
                return .needsSignIn(reason: "the password could not be read: \(error.localizedDescription)")
            }
            guard let secretData, let secret = String(data: secretData, encoding: .utf8) else {
                await quit(wire)
                return .needsSignIn(reason: "no password is saved for this account")
            }
            let r: SMTPReply
            if mechanism == "PLAIN" {
                let token = Data(("\0" + username + "\0" + secret).utf8).base64EncodedString()
                try await wire.command("AUTH PLAIN \(token)", timeout: t, stage: "AUTH")
                r = try await wire.reply(timeout: t, stage: "AUTH")
            } else {
                try await wire.command("AUTH LOGIN", timeout: t, stage: "AUTH")
                var step = try await wire.reply(timeout: t, stage: "AUTH")
                if step.code == 334 {
                    try await wire.command(Data(username.utf8).base64EncodedString(), timeout: t, stage: "AUTH")
                    step = try await wire.reply(timeout: t, stage: "AUTH")
                }
                if step.code == 334 {
                    try await wire.command(Data(secret.utf8).base64EncodedString(), timeout: t, stage: "AUTH")
                    step = try await wire.reply(timeout: t, stage: "AUTH")
                }
                r = step
            }
            return await authResult(wire, r)
        case .oauth2(let username, let tokens, let audience):
            guard mechanisms.contains("XOAUTH2") else {
                await quit(wire)
                return .needsSignIn(reason: "\(settings.host) does not offer OAuth sign-in (XOAUTH2)")
            }
            var refreshed = false
            while true {
                let token: String
                do {
                    try permission(NetworkAsk(accountID: accountID, host: settings.authorizationHost ?? settings.host,
                                              destination: .authorization, operation: .oauthRefresh))
                    token = refreshed ? try await tokens.refreshAfterRejection(account: accountID, audience: audience)
                                      : try await tokens.accessToken(for: accountID, audience: audience)
                } catch {
                    await quit(wire)
                    if case OAuthError.reauthorisationNeeded = error { return .needsSignIn(reason: "this account needs you to sign in again") }
                    return .retry(reason: "a sign-in token could not be obtained: \(error.localizedDescription)", after: nil, quota: false, automatic: true)
                }
                let blob = Data("user=\(username)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
                try await wire.command("AUTH XOAUTH2 \(blob)", timeout: t, stage: "AUTH")
                var r = try await wire.reply(timeout: t, stage: "AUTH")
                if r.code == 334 {
                    // The error detail (base64 JSON); an empty line ends the exchange.
                    try await wire.command("", timeout: t, stage: "AUTH")
                    r = try await wire.reply(timeout: t, stage: "AUTH")
                }
                if r.code == 535 && !refreshed { refreshed = true; continue }
                return await authResult(wire, r)
            }
        }
    }

    private func authResult(_ wire: SMTPWire, _ r: SMTPReply) async -> SubmissionOutcome? {
        if r.code == 235 { return nil }
        await quit(wire)
        if (400..<500).contains(r.code) {
            return .retry(reason: "sign-in is temporarily unavailable: \(r.summary)", after: nil, quota: false, automatic: true)
        }
        return .needsSignIn(reason: "the server did not accept the sign-in: \(r.summary)")
    }

    /// Sending quota / rate limit — not the recipient's full mailbox (X.2.2).
    static func isQuota(_ r: SMTPReply) -> Bool {
        if let e = r.enhanced {
            if e.hasSuffix(".2.2") { return false }
            if e.hasSuffix(".4.5") || e == "4.7.0" && r.text.lowercased().contains("rate") { return true }
        }
        let text = r.text.lowercased()
        return ["sending quota", "quota exceeded", "rate limit", "sending limit", "too many messages", "daily user sending"].contains { text.contains($0) }
    }

    static func classify(_ r: SMTPReply, stage: String) -> SubmissionOutcome {
        if isQuota(r) {
            return .retry(reason: "the account's sending limit was reached: \(r.summary)", after: 3600, quota: true, automatic: true)
        }
        if r.code == 530 || r.code == 535 { return .needsSignIn(reason: r.summary) }
        if (400..<500).contains(r.code) {
            return .retry(reason: "the server refused \(stage) for now: \(r.summary)", after: nil, quota: false, automatic: true)
        }
        return .rejected(reason: "the server refused \(stage): \(r.summary)", rejectedRecipients: [])
    }
}
